# Docker/OCI registry access through skopeo. No container runtime is involved:
# skopeo only downloads the image manifest, configuration and layer blobs.

docker_normalize_image_ref() {
    local ref="$1"

    ref="${ref#docker://}"
    ref="${ref#oci://}"
    ref="${ref#oci:}"
    ref="${ref#docker:}"
    ref="${ref%/}"

    [[ -n "$ref" ]] || return 1
    [[ "$ref" != *[[:space:]]* && "$ref" != *$'\n'* ]] || return 1
    printf '%s' "$ref"
}

docker_storage_base() {
    local user home base
    local -a passwd=()

    if [[ -n "$VED_DOCKER_STORAGE" ]]; then
        printf '%s' "$VED_DOCKER_STORAGE"
        return 0
    fi

    user="${SUDO_USER:-${VED_GUI_USER:-}}"
    if [[ -n "$user" && "$user" != "root" ]]; then
        IFS=: read -r -a passwd <<<"$(getent passwd "$user" 2>/dev/null || true)"
        if ((${#passwd[@]} >= 6)); then
            home="${passwd[5]}"
        fi
    fi
    [[ -n "${home:-}" ]] || home="${HOME:-/root}"

    base="${XDG_DATA_HOME:-$home/.local/share}/ved/docker"
    printf '%s' "$base"
}

docker_image_id() {
    local ref="$1"
    printf '%s' "$ref" | sha256sum | cut -c1-16
}

# The skopeo dir: transport stores blobs as bare hex digests, while manifests
# reference them with the algorithm prefix (sha256:...).
docker_blob_path() {
    local dir="$1"
    local digest="$2"
    printf '%s/%s' "$dir" "${digest#*:}"
}

docker_image_cache_dir() {
    printf '%s/images/%s' "$(docker_storage_base)" "$(docker_image_id "$1")"
}

docker_rootfs_dir() {
    printf '%s/rootfs/%s' "$(docker_storage_base)" "$(docker_image_id "$1")"
}

docker_registry_require() {
    have skopeo || die "$(t docker_skopeo_missing)"
    have tar || die "$(t docker_tar_missing)"
}

docker_registry_cache_valid() {
    local dir="$1"
    local manifest="$dir/manifest.json"
    local digest

    [[ -s "$manifest" && -f "$dir/reference" ]] || return 1
    while IFS= read -r digest; do
        [[ -n "$digest" && -f "$(docker_blob_path "$dir" "$digest")" ]] || return 1
    done < <(docker_image_all_digests "$manifest")
    return 0
}

docker_registry_pull() {
    local ref="$1"
    local dest="$2"
    local tmp="${dest}.tmp.$$"
    local arch=""
    local -a args=(copy)

    mkdir -p "$dest" 2>/dev/null || return 1
    if docker_registry_cache_valid "$dest"; then
        info "$(t docker_image_cached "$ref")"
        return 0
    fi

    if [[ "$VED_ARCH" != "auto" ]]; then
        case "$VED_ARCH" in
            x86_64) arch="amd64" ;;
            aarch64) arch="arm64" ;;
        esac
        if [[ -n "$arch" ]] && skopeo copy --help 2>/dev/null | grep -q -- '--override-arch'; then
            args+=("--override-arch=$arch" "--override-os=linux")
        fi
    fi

    rm -rf -- "$tmp"
    mkdir -p "$tmp" || return 1
    info "$(t docker_pulling "$ref")"
    if ! skopeo "${args[@]}" "docker://$ref" "dir:$tmp"; then
        rm -rf -- "$tmp"
        return 1
    fi

    rm -rf -- "$dest"
    mv -- "$tmp" "$dest" || return 1
    printf '%s\n' "$ref" >"$dest/reference"
    return 0
}

docker_registry_list_images() {
    local base dir reference
    base="$(docker_storage_base)/images"
    [[ -d "$base" ]] || return 0

    for dir in "$base"/*; do
        [[ -f "$dir/manifest.json" ]] || continue
        reference="$(cat "$dir/reference" 2>/dev/null || printf '%s' "${dir##*/}")"
        printf '%s\n' "$reference"
    done
}

docker_registry_prune() {
    local base="$1"
    local image_dir root_dir image_id used
    local -a keep=()

    for root_dir in "$base/rootfs"/*; do
        [[ -f "$root_dir/.ved-docker-image" ]] || continue
        read -r used <"$root_dir/.ved-docker-image" || true
        [[ -n "$used" ]] && keep+=("$used")
    done

    for image_dir in "$base/images"/*; do
        [[ -d "$image_dir" ]] || continue
        image_id="${image_dir##*/}"
        local found=0
        if ((${#keep[@]} > 0)); then
            for used in "${keep[@]}"; do
                if [[ "$used" == "$image_id" ]]; then
                    found=1
                fi
            done
        fi
        if ((found == 0)); then
            info "$(t docker_image_removed "$image_id")"
            rm -rf -- "$image_dir"
        fi
    done
}
