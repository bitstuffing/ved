# OCI/Docker image metadata. skopeo copies the image into a local directory;
# these helpers read the manifest and configuration blob from that directory.

docker_image_all_digests() {
    local manifest="$1"

    [[ -r "$manifest" ]] || return 0
    grep -o '"digest"[[:space:]]*:[[:space:]]*"[^"]*"' "$manifest" 2>/dev/null |
        sed -E 's/.*"digest"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true
}

docker_image_config_digest() {
    local manifest="$1"
    local value=""

    [[ -r "$manifest" ]] || return 0
    value="$(tr -d '\r\n' <"$manifest" |
        sed -n 's/.*"config"[[:space:]]*:[[:space:]]*{[^}]*"digest"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
        head -n1)"
    [[ -n "$value" ]] || value="$(docker_image_all_digests "$manifest" | head -n1)"
    printf '%s' "$value"
}

docker_image_layer_digests() {
    local manifest="$1"
    local value=""

    [[ -r "$manifest" ]] || return 0
    value="$(tr -d '\r\n' <"$manifest" | awk '
        {
            if (!match($0, /"layers"[[:space:]]*:[[:space:]]*\[/)) next
            rest = substr($0, RSTART + RLENGTH)
            sub(/\].*/, "", rest)
            while (match(rest, /"digest"[[:space:]]*:[[:space:]]*"[^"]+"/)) {
                item = substr(rest, RSTART, RLENGTH)
                sub(/^[^"]*"[^"]*"[[:space:]]*:[[:space:]]*"/, "", item)
                sub(/"$/, "", item)
                print item
                rest = substr(rest, RSTART + RLENGTH)
            }
        }
    ')"
    if [[ -n "$value" ]]; then
        printf '%s\n' "$value"
    else
        docker_image_all_digests "$manifest" | tail -n +2
    fi
}

docker_image_config_path() {
    local dir="$1"
    local digest

    digest="$(docker_image_config_digest "$dir/manifest.json")"
    [[ -n "$digest" ]] || return 1
    docker_blob_path "$dir" "$digest"
}

# Flattening the JSON makes these simple scanners work for both compact and
# pretty-printed config blobs, without a JSON library or an interpreter.
docker_json_scalar() {
    local file="$1"
    local key="$2"
    local value=""

    [[ -r "$file" ]] || return 0
    value="$(tr -d '\r\n' <"$file" |
        sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\\1/p" |
        head -n1)"
    printf '%s' "$value"
}

docker_json_array_values() {
    local file="$1"
    local key="$2"

    [[ -r "$file" ]] || return 0
    tr -d '\r\n' <"$file" | awk -v key="$key" '
        {
            pattern = "\"" key "\"[[:space:]]*:[[:space:]]*\\["
            if (!match($0, pattern)) next
            rest = substr($0, RSTART + RLENGTH)
            sub(/\].*/, "", rest)
            while (match(rest, /"[^"]*"/)) {
                item = substr(rest, RSTART + 1, RLENGTH - 2)
                if (length(item)) print item
                rest = substr(rest, RSTART + RLENGTH)
            }
        }
    '
}

docker_env_is_reserved() {
    local key="$1"

    case "$key" in
        HOME|USER|LOGNAME|PATH|TERM|SHELL|LANG|DISPLAY|WAYLAND_DISPLAY|XAUTHORITY|DBUS_*|XDG_*) return 0 ;;
    esac
    return 1
}

docker_image_load_metadata() {
    local dir="$1"
    local config item key

    VED_DOCKER_ENV=()
    VED_GUEST_IMAGE_ENV=()
    VED_DOCKER_ENTRYPOINT=()
    VED_DOCKER_CMD=()
    VED_DOCKER_WORKDIR=""
    VED_DOCKER_ARCH=""
    VED_DOCKER_OS=""

    config="$(docker_image_config_path "$dir")" || return 1
    [[ -r "$config" ]] || return 1

    while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        key="${item%%=*}"
        docker_env_is_reserved "$key" || VED_GUEST_IMAGE_ENV+=("$item")
    done < <(docker_json_array_values "$config" Env)

    mapfile -t VED_DOCKER_ENTRYPOINT < <(docker_json_array_values "$config" Entrypoint)
    mapfile -t VED_DOCKER_CMD < <(docker_json_array_values "$config" Cmd)
    VED_DOCKER_WORKDIR="$(docker_json_scalar "$config" WorkingDir)"
    VED_DOCKER_ARCH="$(docker_json_scalar "$config" architecture)"
    VED_DOCKER_OS="$(docker_json_scalar "$config" os)"
    return 0
}

docker_image_check_platform() {
    local host_arch image_arch image_os

    image_arch="${VED_DOCKER_ARCH:-}"
    image_os="${VED_DOCKER_OS:-linux}"
    host_arch="$(uname -m)"

    case "${image_os,,}" in
        linux|'') ;;
        *) die "$(t docker_platform_mismatch "$image_os/$image_arch" "$host_arch")" ;;
    esac

    [[ -n "$image_arch" ]] || return 0

    case "$image_arch" in
        amd64|x86_64)
            [[ "$host_arch" == "x86_64" ]] ||
                die "$(t docker_platform_mismatch "$image_os/$image_arch" "$host_arch")"
            ;;
        arm64|aarch64)
            [[ "$host_arch" == "aarch64" ]] ||
                die "$(t docker_platform_mismatch "$image_os/$image_arch" "$host_arch")"
            ;;
        *)
            die "$(t docker_platform_mismatch "$image_os/$image_arch" "$host_arch")"
            ;;
    esac
}

docker_join_quoted() {
    local result="" item

    for item in "$@"; do
        [[ -n "$result" ]] && result+=" "
        result+="$(shell_quote_posix "$item")"
    done
    printf '%s' "$result"
}

docker_image_default_command() {
    local -a parts=()

    if ((${#VED_DOCKER_ENTRYPOINT[@]} > 0)); then
        parts+=("${VED_DOCKER_ENTRYPOINT[@]}")
    fi
    if ((${#VED_DOCKER_CMD[@]} > 0)); then
        parts+=("${VED_DOCKER_CMD[@]}")
    fi
    ((${#parts[@]} > 0)) || return 1
    docker_join_quoted "${parts[@]}"
}
