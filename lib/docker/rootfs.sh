# Assemble OCI layers into a persistent plain directory. No overlayfs, no
# container runtime: layers are extracted in order onto a normal rootfs.

docker_layer_stream() {
    local mode="$1"
    local blob="$2"
    local root="${3:-}"
    local magic

    magic="$(od -An -tx1 -N4 "$blob" 2>/dev/null | tr -d ' \n')"

    case "$magic" in
        1f8b*)
            if [[ "$mode" == "list" ]]; then
                tar -tzf "$blob"
            else
                tar --exclude='.wh.*' --exclude='*/.wh.*' -xzpf "$blob" -C "$root"
            fi
            ;;
        fd377a585a00*)
            if tar --help 2>/dev/null | grep -q -- '--zstd'; then
                if [[ "$mode" == "list" ]]; then
                    tar --zstd -tf "$blob"
                else
                    tar --zstd --exclude='.wh.*' --exclude='*/.wh.*' -xpf "$blob" -C "$root"
                fi
            else
                have zstd || die "$(t docker_zstd_missing)"
                if [[ "$mode" == "list" ]]; then
                    zstd -dc "$blob" | tar -tf -
                else
                    zstd -dc "$blob" |
                        tar --exclude='.wh.*' --exclude='*/.wh.*' -xpf - -C "$root"
                fi
            fi
            ;;
        425a68*)
            if [[ "$mode" == "list" ]]; then
                tar -tjf "$blob"
            else
                tar --exclude='.wh.*' --exclude='*/.wh.*' -xjpf "$blob" -C "$root"
            fi
            ;;
        *)
            if [[ "$mode" == "list" ]]; then
                tar -tf "$blob"
            else
                tar --exclude='.wh.*' --exclude='*/.wh.*' -xpf "$blob" -C "$root"
            fi
            ;;
    esac
}

docker_tar_path() {
    local path="$1"
    while [[ "$path" == ./* ]]; do
        path="${path#./}"
    done
    path="${path%/}"
    printf '%s' "$path"
}

docker_path_is_safe() {
    local path="$1"

    [[ -n "$path" ]] || return 1
    [[ "$path" != /* ]] || return 1
    [[ "$path" != ".." && "$path" != ../* && "$path" != */../* && "$path" != */.. ]] || return 1
    return 0
}

docker_path_has_symlink_component() {
    local root="$1"
    local path="$2"
    local current="$root"
    local part
    local -a parts=()

    IFS='/' read -r -a parts <<<"$path"
    for part in "${parts[@]}"; do
        [[ -n "$part" && "$part" != "." ]] || continue
        current="$current/$part"
        if [[ -L "$current" ]]; then
            return 0
        fi
    done
    return 1
}

docker_whiteout_info() {
    local path="$1"
    local name dir target

    name="${path##*/}"
    dir="${path%/*}"
    [[ "$dir" != "$path" ]] || dir="."

    case "$name" in
        .wh..wh..opq)
            printf 'opq|%s|\n' "$dir"
            return 0
            ;;
        .wh.*)
            target="${name#.wh.}"
            [[ -n "$target" ]] || return 1
            if [[ "$dir" == "." ]]; then
                printf 'file|.|%s\n' "$target"
            else
                printf 'file|%s|%s\n' "$dir" "$target"
            fi
            return 0
            ;;
    esac
    return 1
}

docker_layer_clear_whiteouts() {
    local blob="$1"
    local root="$2"
    local path info kind dir target

    [[ -n "$root" ]] || return 1

    while IFS= read -r path; do
        path="$(docker_tar_path "$path")"
        [[ -n "$path" ]] || continue
        docker_path_is_safe "$path" ||
            die "$(t docker_unsafe_layer "$path")"

        info="$(docker_whiteout_info "$path")" || continue
        IFS='|' read -r kind dir target <<<"$info"

        if docker_path_has_symlink_component "$root" "$dir"; then
            die "$(t docker_unsafe_layer "$path")"
        fi

        if [[ "$kind" == "opq" ]]; then
            if [[ "$dir" == "." || ! -d "$root/$dir" ]]; then
                continue
            fi
            find "$root/$dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
        else
            [[ "$target" != "." && -n "$target" ]] || continue
            if [[ "$dir" == "." ]]; then
                rm -rf -- "${root:?}/$target" 2>/dev/null || true
            else
                rm -rf -- "${root:?}/$dir/$target" 2>/dev/null || true
            fi
        fi
    done < <(docker_layer_stream list "$blob")
}

docker_layer_remove_markers() {
    local blob="$1"
    local root="$2"
    local path

    while IFS= read -r path; do
        path="$(docker_tar_path "$path")"
        [[ "${path##*/}" == .wh.* ]] || continue
        docker_path_is_safe "$path" || continue
        rm -f -- "$root/$path" 2>/dev/null || true
    done < <(docker_layer_stream list "$blob")
}

docker_layer_apply() {
    local blob="$1"
    local root="$2"

    [[ -f "$blob" ]] || die "$(t docker_layer_missing "$blob")"
    docker_layer_clear_whiteouts "$blob" "$root"
    docker_layer_stream extract "$blob" "$root" ||
        die "$(t docker_layer_failed "$blob")"
    docker_layer_remove_markers "$blob" "$root"
}

docker_rootfs_layers_file() {
    printf '%s/.ved-docker-layers' "$1"
}

# OCI images often define a desktop user whose home directory is not part of
# the image (for example lscr.io/linuxserver images). Without this, the guest
# desktop starts as that UID but cannot write any configuration.
docker_ensure_guest_home() {
    local root="$1"
    local user="$2"
    local home host_home uid gid passwd_spec subdir
    local -a subdirs=(
        .config .config/xfce4/labwc .cache .local/share .local/state
        Desktop Downloads Templates Public Documents Music Pictures Videos
    )

    [[ -n "$user" && -r "$root/etc/passwd" ]] || return 0
    home="$(awk -F: -v u="$user" '$1 == u {print $6; exit}' "$root/etc/passwd")"
    [[ -n "$home" && "$home" != "/" && "$home" != /*..* ]] || return 0

    passwd_spec="$(awk -F: -v u="$user" '$1 == u {print $3 ":" $4; exit}' "$root/etc/passwd")"
    uid="${VED_GUEST_UID:-${passwd_spec%%:*}}"
    gid="${VED_GUEST_GID:-${passwd_spec##*:}}"
    [[ -n "$uid" ]] || uid=0
    [[ -n "$gid" ]] || gid="$uid"
    host_home="$root$home"

    if [[ ! -d "$host_home" ]]; then
        info "$(t docker_home_prepared "$home")"
        mkdir -p "$host_home" 2>/dev/null || return 0
    fi

    for subdir in "${subdirs[@]}"; do
        mkdir -p "$host_home/$subdir" 2>/dev/null || true
    done

    chown -R "$uid:$gid" "$host_home" 2>/dev/null || true
    chmod 700 "$host_home" 2>/dev/null || true
}

docker_rootfs_write_hostname() {
    local root="$1"
    local ref="$2"
    local name="${ref##*/}"

    name="${name%%:*}"
    name="${name//[^A-Za-z0-9._-]/-}"
    [[ -n "$name" ]] || name="ved-docker"

    mkdir -p "$root/etc"
    if [[ ! -e "$root/etc/hostname" ]]; then
        printf '%s\n' "$name" >"$root/etc/hostname"
    fi
}

docker_rootfs_prepare() {
    local image_dir="$1"
    local image_ref="$2"
    local manifest="$image_dir/manifest.json"
    local root digest blob applied image_id
    local existed=1

    root="$(docker_rootfs_dir "$image_ref")"
    image_id="$(docker_image_id "$image_ref")"

    if [[ "$VED_DOCKER_RESET" -eq 1 && -d "$root" ]]; then
        info "$(t docker_rootfs_reset "$root")"
        rm -rf -- "$root"
        existed=0
    fi
    [[ -d "$root" ]] || existed=0

    mkdir -p "$root" || die "$(t docker_rootfs_failed "$root")"
    printf '%s\n' "$image_id" >"$root/.ved-docker-image"

    applied="$(docker_rootfs_layers_file "$root")"
    if [[ "$existed" -eq 0 || ! -f "$applied" ]]; then
        : >"$applied" 2>/dev/null || true
    fi

    while IFS= read -r digest; do
        [[ -n "$digest" ]] || continue
        grep -Fxq -- "$digest" "$applied" && continue
        blob="$(docker_blob_path "$image_dir" "$digest")"
        info "$(t docker_layer_apply "${digest#sha256:}")"
        docker_layer_apply "$blob" "$root"
        printf '%s\n' "$digest" >>"$applied"
    done < <(docker_image_layer_digests "$manifest")

    mkdir -p "$root/dev" "$root/proc" "$root/sys" "$root/run" "$root/tmp"
    chmod 1777 "$root/tmp" 2>/dev/null || true
    docker_rootfs_write_hostname "$root" "$image_ref"

    VED_DOCKER_ROOTFS="$root"
    return 0
}
