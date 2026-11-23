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

    if have python3; then
        value="$(python3 - "$manifest" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        data = json.load(handle)
    print(data.get("config", {}).get("digest", ""))
except Exception:
    pass
PY
)"
    fi
    [[ -n "$value" ]] || value="$(docker_image_all_digests "$manifest" | head -n1)"
    printf '%s' "$value"
}

docker_image_layer_digests() {
    local manifest="$1"
    local value=""

    if have python3; then
        value="$(python3 - "$manifest" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        data = json.load(handle)
    for layer in data.get("layers", []) or []:
        digest = layer.get("digest")
        if digest:
            print(digest)
except Exception:
    pass
PY
)"
    fi
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

docker_json_scalar() {
    local file="$1"
    local key="$2"
    local value=""

    [[ -r "$file" ]] || return 0

    if have python3; then
        value="$(python3 - "$file" "$key" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        data = json.load(handle)
    section = data.get("config") or {}
    value = section.get(sys.argv[2], data.get(sys.argv[2], ""))
    if value is not None:
        print(value)
except Exception:
    pass
PY
)"
    else
        value="$(sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\\1/p" \
            "$file" | head -n1)"
    fi

    printf '%s' "$value"
}

docker_json_array_values() {
    local file="$1"
    local key="$2"

    [[ -r "$file" ]] || return 0

    if have python3; then
        python3 - "$file" "$key" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        data = json.load(handle)
    section = data.get("config") or {}
    for item in section.get(sys.argv[2], data.get(sys.argv[2], [])) or []:
        print(item)
except Exception:
    pass
PY
    else
        sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\[\(.*\)\].*/\\1/p" "$file" |
            head -n1 |
            tr ',' '\n' |
            sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//' |
            sed '/^$/d'
    fi
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
