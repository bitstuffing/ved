VED_VERSION="2.1.0"

VED_BACKEND="${VED_BACKEND:-qemu}"
VED_BACKEND_SET="${VED_BACKEND_SET:-0}"
VED_LANG="${VED_LANG:-}"
VED_CONFIG="${VED_CONFIG:-}"
VED_ASSUME_YES="${VED_ASSUME_YES:-0}"
VED_DRY_RUN="${VED_DRY_RUN:-0}"
VED_VERBOSE="${VED_VERBOSE:-0}"
VED_NO_INSTALL="${VED_NO_INSTALL:-0}"
VED_KEEP_TEMP="${VED_KEEP_TEMP:-0}"
VED_SHOW_HELP=0
VED_SHOW_VERSION=0

VED_DISK="${VED_DISK:-}"
VED_IMAGE="${VED_IMAGE:-}"
VED_ROOT_PARTITION="${VED_ROOT_PARTITION:-}"
VED_ESP="${VED_ESP:-}"
VED_GUEST_OS="${VED_GUEST_OS:-auto}"
VED_EFI_LOADER="${VED_EFI_LOADER:-}"
VED_EFI_LOADER_SET="${VED_EFI_LOADER_SET:-0}"
VED_STORAGE_MODE="${VED_STORAGE_MODE:-}"
VED_RAM="${VED_RAM:-}"
VED_CPUS="${VED_CPUS:-}"
VED_DISPLAY_MODE="${VED_DISPLAY_MODE:-auto}"
VED_GL="${VED_GL:-auto}"
VED_RENDER_NODE="${VED_RENDER_NODE:-}"
VED_ACCEL="${VED_ACCEL:-auto}"
VED_TPM="${VED_TPM:-auto}"
VED_SECURE_BOOT="${VED_SECURE_BOOT:-0}"
VED_BOOT_MENU="${VED_BOOT_MENU:-1}"
VED_NETWORK="${VED_NETWORK:-user}"
VED_USER="${VED_USER:-}"
VED_COMMAND="${VED_COMMAND:-}"
VED_SHELL="${VED_SHELL:-pwsh}"
VED_SHELL_SET="${VED_SHELL_SET:-0}"
VED_WINDOWS_WRITE="${VED_WINDOWS_WRITE:-0}"
VED_WINDOWS_DRIVE="${VED_WINDOWS_DRIVE:-C}"
VED_WINDOWS_MOUNT=""
VED_WINDOWS_SCRIPT_DIR=""
VED_GRAPHICAL="${VED_GRAPHICAL:-0}"
VED_BOOT="${VED_BOOT:-0}"
VED_SESSION="${VED_SESSION:-auto}"
VED_SESSION_SET="${VED_SESSION_SET:-0}"
VED_GUI_TARGET="${VED_GUI_TARGET:-auto}"
VED_GUEST_DISPLAY="${VED_GUEST_DISPLAY:-}"
VED_NESTED_DISPLAY="${VED_NESTED_DISPLAY:-}"
VED_NESTED_PID="${VED_NESTED_PID:-}"
VED_ARCH="${VED_ARCH:-auto}"
VED_YES_ALL=0
VED_VERSION_STRING="$VED_VERSION"

VED_USB_DEVICES=()
VED_BT_RESET=()
VED_USB_AUTO="${VED_USB_AUTO:-auto}"
VED_USB_ADDED=()
VED_USB_SUMMARY=()
if [[ -n "${VED_USB_DEVICES_ENV:-}" ]]; then
    read -r -a VED_USB_DEVICES <<<"$VED_USB_DEVICES_ENV"
elif [[ -n "${VED_USB_DEVICES:-}" ]]; then
    read -r -a VED_USB_DEVICES <<<"$VED_USB_DEVICES"
fi
if [[ -n "${VED_BT_RESET_ENV:-}" ]]; then
    read -r -a VED_BT_RESET <<<"$VED_BT_RESET_ENV"
elif [[ -n "${VED_BT_RESET:-}" ]]; then
    read -r -a VED_BT_RESET <<<"$VED_BT_RESET"
fi

VED_DISTRO_ID=""
VED_DISTRO_NAME=""
VED_DISTRO_LIKE=""
VED_PKG_FAMILY=""
VED_PKG_MGR=""

VED_GUI_USER=""
VED_GUI_UID=""
VED_GUI_GID=""
VED_GUI_HOME=""
VED_GUI_RUNTIME=""
VED_GUI_SESSION_TYPE="${XDG_SESSION_TYPE:-}"
VED_HOST_RUNTIME_DIR=""
VED_GUEST_RUNTIME=""
VED_GUEST_WAYLAND_DISPLAY=""
VED_GUEST_UID=""
VED_GUEST_GID=""
VED_GUEST_SESSION_TYPE=""
VED_GUEST_NO_X11=0
VED_WAYLAND_EXPORT_FAILED=0
VED_GUEST_SESSION_DESKTOP=""
VED_GUEST_CURRENT_DESKTOP=""
VED_GUEST_HOSTNAME=""
VED_GUEST_SYSTEM_BUS_ADDRESS=""
VED_GUEST_SYSTEM_BUS_PID=""
VED_GUEST_LOGIN1_STUB_PID=""
VED_NSPAWN_GUEST_BUS_DIR=""
VED_UTS_NAMESPACE_OK=0

VED_OVMF_CODE=""
VED_OVMF_VARS_TEMPLATE=""
VED_OVMF_CODE_FORMAT="raw"
VED_OVMF_VARS_FORMAT="raw"
VED_OVMF_CODE_SECBOOT=""
VED_OVMF_VARS_SECBOOT=""

VED_RUN_DIR=""
VED_RUN_ID=""
VED_VM_DIR=""
VED_SOURCE_MOUNT=""
VED_COPY_MOUNT=""
VED_CHROOT_DIR=""
VED_GUEST_XAUTHORITY=""
VED_ESP_IMAGE=""
VED_VARS_TEMP=""
VED_QEMU_LOG=""
VED_SPICE_SOCKET=""
VED_QEMU_PID=""
VED_SWTPM_PID=""
VED_RENDER_NODES=()
VED_ACCEL_ACTUAL=""
VED_DISPLAY_ACTUAL=""
VED_IMAGE_FORMAT=""
NSPAWN_ARGS=()
VED_DISPLAY_VIEWER=0
VED_AUDIO_ARGS=()
VED_TPM_ARGS=()
VED_USB_ARGS=()
VED_QEMU_ARGS=()
VED_STORAGE_OPTS=()
VED_EXTRA_BINDS=()

VED_CLEANUP_PIDS=()
VED_CLEANUP_MOUNTS=()
VED_CLEANUP_FILES=()
VED_CLEANUP_DIRS=()
VED_CLEANUP_DONE=0

info() {
    printf '%s\n' "$*"
}

warn() {
    printf '%s %s\n' "$(t warn_prefix)" "$*" >&2
}

die() {
    printf '%s %s\n' "$(t error_prefix)" "$*" >&2
    exit 1
}

debug() {
    if [[ "${VED_VERBOSE:-0}" -eq 1 ]]; then
        printf 'DEBUG: %s\n' "$*" >&2
    fi
}

have() {
    command -v "$1" >/dev/null 2>&1
}

# GNOME Keyring allocates libgcrypt secure memory. In a container/chroot the
# process keeps the host UID, so the system-wide RLIMIT_MEMLOCK can already be
# exhausted by the host session even when this shell still shows several MB.
# Try to raise both limits before entering a graphical session. This only works
# when the caller really has CAP_SYS_RESOURCE; systemd-nspawn additionally sets
# LimitMEMLOCK on its scope unit, which normally has that capability.
raise_graphical_memlock_limit() {
    [[ "${VED_GRAPHICAL:-0}" -eq 1 ]] || return 0

    local soft hard
    soft="$(ulimit -Sl 2>/dev/null || printf '0')"
    hard="$(ulimit -Hl 2>/dev/null || printf '0')"

    [[ "$soft" == "unlimited" ]] && return 0

    if have prlimit; then
        prlimit --memlock=unlimited:unlimited --pid $$ >/dev/null 2>&1 && return 0
        prlimit --memlock=134217728:134217728 --pid $$ >/dev/null 2>&1 && return 0
    fi

    if [[ "$hard" == "unlimited" ]]; then
        ulimit -Sl unlimited >/dev/null 2>&1 && return 0
    elif [[ "$hard" =~ ^[0-9]+$ ]] && ((hard > soft)); then
        ulimit -Sl "$hard" >/dev/null 2>&1 && return 0
    fi

    warn "$(t memlock_raise_failed)"
    return 1
}

# libgcrypt enters FIPS mode if /etc/gcrypt/fips_enabled merely exists. FIPS
# mode forbids its normal unlocked secure-memory fallback, so GNOME Keyring
# aborts with "out of core in secure memory" when mlock cannot be satisfied.
# Mask that force switch for graphical guests; a nested desktop is not a FIPS
# boundary, and the guest's original file is restored when the mount is removed.
prepare_guest_nonfips_config() {
    local root="$1"
    local file="$root/etc/gcrypt/fips_enabled"

    [[ -d "$root/etc" ]] || return 0
    mkdir -p "$(dirname "$file")" 2>/dev/null || return 1
    if [[ -L "$file" ]]; then
        warn "$(t guest_fips_mask_failed)"
        return 1
    fi
    if [[ ! -e "$file" ]]; then
        : >"$file" 2>/dev/null || return 1
    fi
    printf '%s' "$file"
}

require_command() {
    have "$1" || die "$(t missing_command "$1")"
}

quote_arg() {
    local value="$1"

    if [[ -z "$value" ]]; then
        printf "''"
    elif [[ "$value" =~ ^[A-Za-z0-9_./:=,@%+-]*$ ]]; then
        printf '%s' "$value"
    else
        printf '%q' "$value"
    fi
}

print_command() {
    local first=1
    local argument

    for argument in "$@"; do
        if [[ "$first" -eq 0 ]]; then
            printf ' '
        fi
        quote_arg "$argument"
        first=0
    done
}

cleanup_add_mount() {
    VED_CLEANUP_MOUNTS+=("$1")
}

cleanup_add_file() {
    VED_CLEANUP_FILES+=("$1")
}

cleanup_add_dir() {
    VED_CLEANUP_DIRS+=("$1")
}

cleanup_add_pid() {
    VED_CLEANUP_PIDS+=("$1")
}

cleanup_run() {
    local item pid index
    [[ "${VED_CLEANUP_DONE:-0}" -eq 0 ]] || return 0
    VED_CLEANUP_DONE=1
    trap - EXIT INT TERM HUP
    set +e

    printf '\n'
    info "$(t cleanup)"

    for pid in "${VED_CLEANUP_PIDS[@]}"; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
        fi
    done

    for ((index = ${#VED_CLEANUP_MOUNTS[@]} - 1; index >= 0; index--)); do
        item="${VED_CLEANUP_MOUNTS[$index]}"
        if mountpoint -q "$item" 2>/dev/null; then
            sync
            umount -R "$item" 2>/dev/null || umount -l "$item" 2>/dev/null
        fi
    done

    if [[ "${VED_KEEP_TEMP:-0}" -eq 1 ]]; then
        info "$(t keeping_temp "$VED_RUN_DIR")"
    else
        for item in "${VED_CLEANUP_FILES[@]}"; do
            [[ -n "$item" && -e "$item" ]] && rm -f -- "$item"
        done

        for ((index = ${#VED_CLEANUP_DIRS[@]} - 1; index >= 0; index--)); do
            item="${VED_CLEANUP_DIRS[$index]}"
            [[ -n "$item" && -d "$item" ]] && rmdir -- "$item" 2>/dev/null
        done
    fi

    info "$(t cleanup_done)"
    return 0
}

sudo_credentials_cached() {
    sudo -n true 2>/dev/null
}

sudo_request_password() {
    local attempts=0
    local max_attempts=3
    local tty_device=""
    local password=""

    if [[ -t 0 ]]; then
        tty_device="/dev/stdin"
    elif ( exec 3<>/dev/tty ) 2>/dev/null; then
        tty_device="/dev/tty"
    fi

    if [[ -z "$tty_device" ]]; then
        return 1
    fi

    while (( attempts < max_attempts )); do
        attempts=$((attempts + 1))
        if ! printf '%s' "$(t sudo_password_prompt)" >"$tty_device" 2>/dev/null; then
            return 1
        fi
        if ! IFS= read -r -s password <"$tty_device" 2>/dev/null; then
            printf '\n' >"$tty_device" 2>/dev/null || true
            return 1
        fi
        printf '\n' >"$tty_device" 2>/dev/null || true

        if printf '%s\n' "$password" | sudo -S -v 2>/dev/null; then
            password=""
            return 0
        fi
        warn "$(t sudo_password_incorrect)"
    done

    password=""
    return 1
}

ensure_root() {
    if [[ "$EUID" -eq 0 ]]; then
        return
    fi

    have sudo || die "$(t root_required)"

    if ! sudo_credentials_cached; then
        sudo_request_password || die "$(t sudo_failed)"
    fi

    info "$(t rerun_sudo)"
    exec sudo \
        --preserve-env=DISPLAY,WAYLAND_DISPLAY,XAUTHORITY,XDG_RUNTIME_DIR,XDG_SESSION_TYPE,DBUS_SESSION_BUS_ADDRESS,VED_LANG,LANG,LC_ALL,LC_MESSAGES,VED_BACKEND,VED_CONFIG,VED_ASSUME_YES,VED_VERBOSE,VED_NO_INSTALL,VED_KEEP_TEMP,VED_SHELL,VED_SHELL_SET,VED_WINDOWS_WRITE,VED_WINDOWS_DRIVE \
        -- "$VED_MAIN" "$@"
}

detect_graphical_user_identity() {
    if [[ -n "${VED_GUI_USER:-}" && "$VED_GUI_USER" != "root" ]]; then
        :
    elif [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        VED_GUI_USER="$SUDO_USER"
    else
        VED_GUI_USER="$(logname 2>/dev/null || true)"
        if [[ -z "$VED_GUI_USER" && "$EUID" -ne 0 ]]; then
            VED_GUI_USER="$(id -un)"
        fi
    fi

    if [[ -z "${VED_GUI_USER:-}" || "$VED_GUI_USER" == "root" ]]; then
        return 1
    fi

    VED_GUI_UID="$(id -u "$VED_GUI_USER" 2>/dev/null)" || return 1
    VED_GUI_GID="$(id -g "$VED_GUI_USER" 2>/dev/null)" || return 1
    VED_GUI_HOME="$(getent passwd "$VED_GUI_USER" | cut -d: -f6)"
    VED_GUI_RUNTIME="/run/user/$VED_GUI_UID"
    VED_SPICE_SOCKET="$VED_GUI_RUNTIME/ved-spice-${VED_RUN_ID}.sock"

    return 0
}

detect_graphical_user() {
    detect_graphical_user_identity ||
        die "$(t gui_user_error) $(t execute_from_session)"

    if [[ ! -d "$VED_GUI_RUNTIME" ]]; then
        warn "$(t runtime_missing "$VED_GUI_RUNTIME")"
    fi

    debug "GUI user: $VED_GUI_USER ($VED_GUI_UID:$VED_GUI_GID) home=$VED_GUI_HOME"
}

detect_graphical_user_optional() {
    if detect_graphical_user_identity; then
        if [[ ! -d "$VED_GUI_RUNTIME" ]]; then
            warn "$(t runtime_missing "$VED_GUI_RUNTIME")"
        fi
        debug "GUI user: $VED_GUI_USER ($VED_GUI_UID:$VED_GUI_GID) home=$VED_GUI_HOME"
    else
        VED_GUI_USER=""
        VED_GUI_UID=""
        VED_GUI_GID=""
        VED_GUI_HOME=""
        VED_GUI_RUNTIME=""
        VED_SPICE_SOCKET=""
        VED_HOST_RUNTIME_DIR=""
        VED_GUEST_RUNTIME=""
        VED_GUEST_WAYLAND_DISPLAY=""
        VED_GUEST_UID=""
        VED_GUEST_GID=""
        VED_GUEST_SESSION_TYPE=""
        VED_GUEST_NO_X11=0
        VED_WAYLAND_EXPORT_FAILED=0
        VED_GUEST_SESSION_DESKTOP=""
        VED_GUEST_CURRENT_DESKTOP=""
        VED_GUEST_HOSTNAME=""
        VED_GUEST_SYSTEM_BUS_ADDRESS=""
        VED_GUEST_SYSTEM_BUS_PID=""
        VED_GUEST_LOGIN1_STUB_PID=""
        VED_UTS_NAMESPACE_OK=0
    fi

    return 0
}

gui_env_args() {
    local runtime="${VED_GUI_RUNTIME:-/run/user/$VED_GUI_UID}"
    printf '%s\0' \
        "HOME=$VED_GUI_HOME" \
        "USER=$VED_GUI_USER" \
        "LOGNAME=$VED_GUI_USER" \
        "DISPLAY=${DISPLAY:-:0}" \
        "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}" \
        "XDG_RUNTIME_DIR=$runtime" \
        "XDG_SESSION_TYPE=${VED_GUI_SESSION_TYPE:-${XDG_SESSION_TYPE:-wayland}}" \
        "XAUTHORITY=${XAUTHORITY:-$VED_GUI_HOME/.Xauthority}" \
        "DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=$runtime/bus}" \
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        "SHELL=${SHELL:-/bin/sh}" \
        "TERM=${TERM:-xterm-256color}" \
        "LANG=${LANG:-C.UTF-8}"
}

run_as_gui_user() {
    local -a env_args=()
    while IFS= read -r -d '' item; do
        env_args+=("$item")
    done < <(gui_env_args)
    runuser -u "$VED_GUI_USER" -- env -i "${env_args[@]}" "$@"
}

make_temp_file() {
    local template="$1"
    local file
    file="$(mktemp "$template")"
    cleanup_add_file "$file"
    printf '%s' "$file"
}

make_temp_dir() {
    local template="$1"
    local dir
    dir="$(mktemp -d "$template")"
    cleanup_add_dir "$dir"
    printf '%s' "$dir"
}

initialize_run_directory() {
    local run_base="${VED_RUNTIME_BASE:-/run/ved}"

    mkdir -p "$run_base"
    chmod 700 "$run_base" 2>/dev/null || true
    VED_RUN_DIR="$(mktemp -d "$run_base/run.XXXXXX")" ||
        die "$(t runtime_prepare_failed "$run_base")"
    chmod 700 "$VED_RUN_DIR"
    VED_RUN_ID="${VED_RUN_DIR##*/}"
    cleanup_add_dir "$VED_RUN_DIR"

    VED_VM_DIR="$VED_RUN_DIR/vm"
    VED_SOURCE_MOUNT="$VED_RUN_DIR/efi-source"
    VED_COPY_MOUNT="$VED_RUN_DIR/efi-copy"
    VED_CHROOT_DIR="$VED_RUN_DIR/root"
    VED_QEMU_LOG="$VED_VM_DIR/qemu.log"

    mkdir -p "$VED_VM_DIR"
    cleanup_add_dir "$VED_VM_DIR"
}

valid_efi_loader_path() {
    local loader="$1"
    local component
    local -a components=()

    [[ -z "$loader" ]] && return 0
    [[ "$loader" != /* && "$loader" != *'//' && "$loader" != *$'\n'* ]] || return 1

    IFS=/ read -r -a components <<<"$loader"
    for component in "${components[@]}"; do
        [[ -n "$component" && "$component" != "." && "$component" != ".." ]] || return 1
    done
}

preload_config() {
    local arg config=""
    while (($#)); do
        case "$1" in
            --config)
                config="${2:-}"
                shift
                ;;
            --config=*)
                config="${1#--config=}"
                ;;
        esac
        shift || break
    done
    [[ -n "$config" ]] || config="${VED_CONFIG:-}"
    [[ -n "$config" ]] || return 0
    [[ -r "$config" ]] || die "$(t config_missing "$config")"
    # shellcheck source=/dev/null
    source "$config"
    VED_CONFIG="$config"
}

parse_cli() {
    local arg
    while (($#)); do
        arg="$1"
        case "$arg" in
            -h|--help)
                VED_SHOW_HELP=1
                ;;
            -V|--version)
                VED_SHOW_VERSION=1
                ;;
            -L|--lang)
                VED_LANG="${2:-}"
                ved_i18n_load
                shift
                ;;
            --lang=*)
                VED_LANG="${arg#--lang=}"
                ved_i18n_load
                ;;
            -b|--backend)
                VED_BACKEND="${2:-}"
                VED_BACKEND_SET=1
                shift
                ;;
            --backend=*)
                VED_BACKEND="${arg#--backend=}"
                VED_BACKEND_SET=1
                ;;
            -d|--disk)
                VED_DISK="${2:-}"
                shift
                ;;
            --disk=*)
                VED_DISK="${arg#--disk=}"
                ;;
            -i|--image)
                VED_IMAGE="${2:-}"
                shift
                ;;
            --image=*)
                VED_IMAGE="${arg#--image=}"
                ;;
            -p|--root-partition|--partition)
                VED_ROOT_PARTITION="${2:-}"
                shift
                ;;
            --root-partition=*|--partition=*)
                VED_ROOT_PARTITION="${arg#*=}"
                ;;
            --esp)
                VED_ESP="${2:-}"
                shift
                ;;
            --esp=*)
                VED_ESP="${arg#--esp=}"
                ;;
            --os)
                VED_GUEST_OS="${2:-}"
                shift
                ;;
            --os=*)
                VED_GUEST_OS="${arg#--os=}"
                ;;
            --efi-loader)
                VED_EFI_LOADER="${2:-}"
                VED_EFI_LOADER_SET=1
                shift
                ;;
            --efi-loader=*)
                VED_EFI_LOADER="${arg#--efi-loader=}"
                VED_EFI_LOADER_SET=1
                ;;
            --storage)
                VED_STORAGE_MODE="${2:-}"
                shift
                ;;
            --storage=*)
                VED_STORAGE_MODE="${arg#--storage=}"
                ;;
            --ram)
                VED_RAM="${2:-}"
                shift
                ;;
            --ram=*)
                VED_RAM="${arg#--ram=}"
                ;;
            --cpus)
                VED_CPUS="${2:-}"
                shift
                ;;
            --cpus=*)
                VED_CPUS="${arg#--cpus=}"
                ;;
            --display)
                VED_DISPLAY_MODE="${2:-}"
                shift
                ;;
            --display=*)
                VED_DISPLAY_MODE="${arg#--display=}"
                ;;
            --gl)
                VED_GL=1
                ;;
            --no-gl)
                VED_GL=0
                ;;
            --render-node)
                VED_RENDER_NODE="${2:-}"
                shift
                ;;
            --render-node=*)
                VED_RENDER_NODE="${arg#--render-node=}"
                ;;
            --accel)
                VED_ACCEL="${2:-}"
                shift
                ;;
            --accel=*)
                VED_ACCEL="${arg#--accel=}"
                ;;
            --tpm)
                VED_TPM=1
                ;;
            --no-tpm)
                VED_TPM=0
                ;;
            --secure-boot)
                VED_SECURE_BOOT=1
                ;;
            --no-secure-boot)
                VED_SECURE_BOOT=0
                ;;
            --boot-menu)
                VED_BOOT_MENU=1
                ;;
            --no-boot-menu)
                VED_BOOT_MENU=0
                ;;
            --network)
                VED_NETWORK="${2:-}"
                shift
                ;;
            --network=*)
                VED_NETWORK="${arg#--network=}"
                ;;
            --usb)
                VED_USB_DEVICES+=("${2:-}")
                shift
                ;;
            --usb=*)
                VED_USB_DEVICES+=("${arg#--usb=}")
                ;;
            --usb-auto)
                VED_USB_AUTO="${2:-}"
                shift
                ;;
            --usb-auto=*)
                VED_USB_AUTO="${arg#--usb-auto=}"
                ;;
            --no-usb|--no-usb-auto)
                VED_USB_AUTO="none"
                ;;
            --reset-bluetooth|--reset-usb)
                VED_BT_RESET+=("${2:-}")
                shift
                ;;
            --reset-bluetooth=*|--reset-usb=*)
                VED_BT_RESET+=("${arg#*=}")
                ;;
            --user)
                VED_USER="${2:-}"
                shift
                ;;
            --user=*)
                VED_USER="${arg#--user=}"
                ;;
            -c|--command)
                VED_COMMAND="${2:-}"
                shift
                ;;
            --command=*)
                VED_COMMAND="${arg#--command=}"
                ;;
            --shell)
                VED_SHELL="${2:-}"
                VED_SHELL_SET=1
                shift
                ;;
            --shell=*)
                VED_SHELL="${arg#--shell=}"
                VED_SHELL_SET=1
                ;;
            --windows-write)
                VED_WINDOWS_WRITE=1
                ;;
            --windows-ro)
                VED_WINDOWS_WRITE=0
                ;;
            --windows-drive)
                VED_WINDOWS_DRIVE="${2:-}"
                shift
                ;;
            --windows-drive=*)
                VED_WINDOWS_DRIVE="${arg#--windows-drive=}"
                ;;
            --graphical)
                VED_GRAPHICAL=1
                ;;
            --boot)
                VED_BOOT=1
                ;;
            --session)
                VED_SESSION="${2:-}"
                VED_SESSION_SET=1
                shift
                ;;
            --session=*)
                VED_SESSION="${arg#--session=}"
                VED_SESSION_SET=1
                ;;
            --app)
                VED_COMMAND="${2:-}"
                VED_SESSION="app"
                VED_SESSION_SET=1
                shift
                ;;
            --app=*)
                VED_COMMAND="${arg#--app=}"
                VED_SESSION="app"
                VED_SESSION_SET=1
                ;;
            --gui|--gui-target|--display-target)
                VED_GUI_TARGET="${2:-}"
                shift
                ;;
            --gui=*|--gui-target=*|--display-target=*)
                VED_GUI_TARGET="${arg#*=}"
                ;;
            --nested)
                VED_GUI_TARGET="nested"
                ;;
            --host-display)
                VED_GUI_TARGET="host"
                ;;
            --arch)
                VED_ARCH="${2:-}"
                shift
                ;;
            --arch=*)
                VED_ARCH="${arg#--arch=}"
                ;;
            --config)
                VED_CONFIG="${2:-}"
                shift
                ;;
            --config=*)
                VED_CONFIG="${arg#--config=}"
                ;;
            -y|--yes)
                VED_ASSUME_YES=1
                ;;
            -n|--dry-run)
                VED_DRY_RUN=1
                ;;
            --no-install)
                VED_NO_INSTALL=1
                ;;
            --keep-temp)
                VED_KEEP_TEMP=1
                ;;
            -v|--verbose)
                VED_VERBOSE=1
                ;;
            --)
                shift
                break
                ;;
            -*)
                die "$(t unknown_option "$arg")"
                ;;
            *)
                die "$(t unexpected_argument "$arg")"
                ;;
        esac
        shift
    done

    case "${VED_BACKEND,,}" in
        qemu|chroot|nspawn) VED_BACKEND="${VED_BACKEND,,}" ;;
        powershell|pwsh|windows) VED_BACKEND="powershell" ;;
        *) die "$(t backend_invalid "$VED_BACKEND")" ;;
    esac

    case "${VED_SHELL,,}" in
        pwsh|powershell) VED_SHELL="pwsh" ;;
        cmd) VED_SHELL="cmd" ;;
        *) die "$(t shell_invalid "$VED_SHELL")" ;;
    esac

    if [[ ! "$VED_WINDOWS_DRIVE" =~ ^[A-Za-z]$ ]]; then
        die "$(t windows_drive_invalid "$VED_WINDOWS_DRIVE")"
    fi
    VED_WINDOWS_DRIVE="${VED_WINDOWS_DRIVE^^}"

    case "${VED_GUEST_OS,,}" in
        auto|linux|windows) VED_GUEST_OS="${VED_GUEST_OS,,}" ;;
        *) die "$(t guest_os_invalid "$VED_GUEST_OS")" ;;
    esac

    case "${VED_USB_AUTO,,}" in
        auto|all|none) VED_USB_AUTO="${VED_USB_AUTO,,}" ;;
        *) die "$(t usb_auto_invalid "$VED_USB_AUTO")" ;;
    esac

    case "${VED_SESSION,,}" in
        auto|shell|app|desktop|system) VED_SESSION="${VED_SESSION,,}" ;;
        *) die "$(t session_invalid "$VED_SESSION")" ;;
    esac

    case "${VED_GUI_TARGET,,}" in
        auto|host|nested) VED_GUI_TARGET="${VED_GUI_TARGET,,}" ;;
        *) die "$(t gui_target_invalid "$VED_GUI_TARGET")" ;;
    esac

    case "${VED_ARCH,,}" in
        auto|'') VED_ARCH="auto" ;;
        x86_64|amd64) VED_ARCH="x86_64" ;;
        aarch64|arm64) VED_ARCH="aarch64" ;;
        *) die "$(t arch_invalid "$VED_ARCH")" ;;
    esac

    case "${VED_STORAGE_MODE,,}" in
        ''|temp|temporary|snapshot) [[ -z "$VED_STORAGE_MODE" ]] || VED_STORAGE_MODE=temp ;;
        persistent|rw) VED_STORAGE_MODE=persistent ;;
        *) die "$(t storage_invalid "$VED_STORAGE_MODE")" ;;
    esac

    if [[ -n "$VED_RAM" && ! "$VED_RAM" =~ ^[1-9][0-9]*([MmGg])?$ ]]; then
        die "$(t invalid_memory)"
    fi

    if [[ "$VED_EFI_LOADER_SET" -eq 1 ]] && ! valid_efi_loader_path "$VED_EFI_LOADER"; then
        die "$(t invalid_efi_loader "$VED_EFI_LOADER")"
    fi

    case "${VED_DISPLAY_MODE,,}" in
        auto|spice-gl|spice|gtk-gl|gtk|sdl|vnc|none) VED_DISPLAY_MODE="${VED_DISPLAY_MODE,,}" ;;
        *) die "$(t display_invalid "$VED_DISPLAY_MODE")" ;;
    esac

    case "${VED_ACCEL,,}" in
        auto|kvm|tcg) VED_ACCEL="${VED_ACCEL,,}" ;;
        *) die "$(t accel_invalid "$VED_ACCEL")" ;;
    esac

    case "${VED_TPM,,}" in
        auto|0|1|on|off|yes|no|swtpm|passthrough)
            case "${VED_TPM,,}" in
                on|yes) VED_TPM=1 ;;
                off|no) VED_TPM=0 ;;
                *) VED_TPM="${VED_TPM,,}" ;;
            esac
            ;;
        *) die "$(t tpm_invalid "$VED_TPM")" ;;
    esac
}

print_version() {
    printf 'ved %s\n' "$VED_VERSION_STRING"
}

ved_main() {
    local run_args=("$@")

    ved_i18n_load
    preload_config "$@"
    parse_cli "$@"
    ved_i18n_load

    if [[ "$VED_SHOW_HELP" -eq 1 ]]; then
        printf '%s\n' "$(t usage)"
        exit 0
    fi

    if [[ "$VED_SHOW_VERSION" -eq 1 ]]; then
        print_version
        exit 0
    fi

    if [[ "$VED_BACKEND_SET" -eq 0 && -t 0 && -z "$VED_IMAGE" ]]; then
        if [[ -z "$VED_DISK" && -z "$VED_ROOT_PARTITION" ]]; then
            select_disk
            run_args+=(--disk "$VED_DISK")
        fi
        select_backend
        run_args+=(--backend "$VED_BACKEND")
    fi

    if [[ "$VED_BACKEND" == "qemu" && -t 0 && "$VED_ARCH" == "auto" ]]; then
        select_arch
        [[ "$VED_ARCH" == "auto" ]] || run_args+=(--arch "$VED_ARCH")
    fi

    if [[ "$VED_BACKEND" != "qemu" && "$VED_BACKEND" != "powershell" && -t 0 ]]; then
        select_session
        run_args+=(--session "$VED_SESSION")
        if [[ "$VED_SESSION" == "app" || "$VED_SESSION" == "desktop" ]]; then
            select_gui_target
            run_args+=(--gui "$VED_GUI_TARGET")
        fi
    fi

    if [[ "$VED_BACKEND" == "powershell" && "$VED_SHELL_SET" -eq 0 && -t 0 ]]; then
        select_shell
        run_args+=(--shell "$VED_SHELL")
    fi

    if [[ "$VED_BACKEND" == "qemu" ]]; then
        detect_guest_arch
        [[ "$VED_ARCH" == "auto" ]] || run_args+=(--arch "$VED_ARCH")
    fi

    ensure_root "${run_args[@]}"

    detect_platform
    ensure_dependencies

    trap cleanup_run EXIT INT TERM HUP
    initialize_run_directory

    case "$VED_BACKEND" in
        qemu) backend_qemu ;;
        chroot) backend_chroot ;;
        nspawn) backend_nspawn ;;
        powershell) backend_powershell ;;
    esac
}
