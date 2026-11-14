declare -gA VED_MESSAGES=()

ved_i18n_detect() {
    local requested="${VED_LANG:-}"
    if [[ -z "$requested" ]]; then
        requested="${LC_ALL:-${LC_MESSAGES:-${LANG:-en}}}"
    fi
    requested="${requested%%.*}"
    requested="${requested%%@*}"
    requested="${requested%%_*}"
    requested="${requested%%-*}"
    requested="${requested,,}"
    case "$requested" in
        ''|c|posix) requested="en" ;;
    esac
    printf '%s' "$requested"
}

ved_i18n_load() {
    local requested locale_file
    requested="$(ved_i18n_detect)"
    VED_MESSAGES=()

    locale_file="$VED_ROOT/locale/en.sh"
    [[ -r "$locale_file" ]] || {
        printf 'ERROR: missing locale file: %s\n' "$locale_file" >&2
        exit 1
    }
    # shellcheck source=/dev/null
    source "$locale_file"

    if [[ "$requested" != "en" ]]; then
        locale_file="$VED_ROOT/locale/$requested.sh"
        if [[ -r "$locale_file" ]]; then
            # shellcheck source=/dev/null
            source "$locale_file"
        else
            printf 'WARNING: unsupported language "%s"; using English.\n' "$requested" >&2
            requested="en"
        fi
    fi

    VED_LANG="$requested"
}

t() {
    local key="$1"
    shift
    local fmt="${VED_MESSAGES[$key]-$key}"
    if (($# > 0)); then
        # shellcheck disable=SC2059
        printf "$fmt" "$@"
    else
        printf '%s' "$fmt"
    fi
}

msg() {
    local key="$1"
    shift
    printf '%s\n' "$(t "$key" "$@")"
}
