# Windows-partition shell backend: native PowerShell 7 (pwsh), or Wine cmd.
# This is deliberately NOT a VM: the NTFS partition is mounted and a Windows
# shell is started around it. It is a compatibility layer, not the installed
# Windows kernel (see the README for the exact limitations).

powershell_binary() {
    if have pwsh; then
        printf 'pwsh'
    elif have powershell; then
        printf 'powershell'
    else
        return 1
    fi
}

powershell_fail_missing() {
    printf '%s %s\n' "$(t error_prefix)" "$(t powershell_missing)" >&2
    powershell_install_hint >&2
    exit 1
}

powershell_existing_mountpoint() {
    local part="$1" mountpoint

    mountpoint="$(lsblk -nrpo MOUNTPOINT "$part" 2>/dev/null | head -n1 || true)"
    [[ -n "$mountpoint" && "$mountpoint" != "[SWAP]" ]] || return 0
    printf '%s' "$mountpoint"
}

powershell_is_hibernated() {
    local root="$1"
    [[ -f "$root/hiberfil.sys" || -f "$root/Windows/System32/hiberfil.sys" ]]
}

powershell_mount_options() {
    local mode="$1"
    local uid="${VED_GUI_UID:-0}" gid="${VED_GUI_GID:-0}"
    local options="$mode,nosuid,nodev"

    if [[ -n "${VED_GUI_USER:-}" && "$uid" != "0" ]]; then
        options+=",uid=$uid,gid=$gid"
    fi
    printf '%s' "$options"
}

powershell_mount_partition() {
    local part="$1" target="$2" mount_type fstype options existing mount_error
    local -a mount_command=()

    existing="$(powershell_existing_mountpoint "$part")"
    if [[ -n "$existing" ]]; then
        VED_WINDOWS_MOUNT="$existing"
        info "$(t windows_using_existing_mount "$existing")"
        if [[ "$VED_WINDOWS_WRITE" -eq 1 ]]; then
            warn "$(t windows_write_existing_mount)"
        fi
        return 0
    fi

    fstype="$(lsblk -nrpo FSTYPE "$part" 2>/dev/null | head -n1 || true)"
    if [[ "${fstype,,}" == *bitlocker* ]]; then
        die "$(t windows_bitlocker "$part")"
    fi

    mount_type="$(windows_mount_type)" || die "$(t windows_ntfs_missing)"

    info "$(t windows_mounting)"
    mkdir -p "$target"
    umount_path "$target"

    options="$(powershell_mount_options ro)"
    mount_command=(mount -t "$mount_type" -o "$options" "$part" "$target")
    if [[ "$VED_DRY_RUN" -eq 1 ]]; then
        info "$(t dry_run)"
        print_command "${mount_command[@]}"
        printf '\n'
        VED_WINDOWS_MOUNT="$target"
        return 0
    fi

    if ! mount_error="$("${mount_command[@]}" 2>&1)"; then
        case "$mount_error" in
            *[Bb]it[Ll]ocker*) die "$(t windows_bitlocker "$part")" ;;
        esac
        debug "mount failed: $mount_error"
        die "$(t windows_mount_failed "$part")"
    fi
    cleanup_add_mount "$target"
    VED_WINDOWS_MOUNT="$target"

    if [[ "$VED_WINDOWS_WRITE" -eq 1 ]]; then
        if powershell_is_hibernated "$target"; then
            die "$(t windows_hibernated)"
        fi
        umount_path "$target"
        options="$(powershell_mount_options rw)"
        mount -t "$mount_type" -o "$options" "$part" "$target" ||
            die "$(t windows_mount_failed "$part")"
        cleanup_add_mount "$target"
    fi

    info "$(t windows_ready "$target")"
}

# Generated .ps1 files are launched as the graphical user (via runuser), so they
# must live in a directory that user can traverse. VED_RUN_DIR is root-only.
powershell_register_script() {
    local file="$1"

    cleanup_add_file "$file"
    if [[ -n "${VED_GUI_UID:-}" && "${VED_GUI_UID}" != "0" ]]; then
        chown "$VED_GUI_UID:${VED_GUI_GID:-$VED_GUI_UID}" "$file" 2>/dev/null || true
    fi
    chmod 600 "$file" 2>/dev/null || true
}

powershell_script_dir() {
    printf '%s' "${VED_WINDOWS_SCRIPT_DIR:-$VED_RUN_DIR}"
}

powershell_prepare_history() {
    local script_dir history_file

    script_dir="$(powershell_script_dir)"
    history_file="$script_dir/PSReadLine_history.txt"
    : >"$history_file" || return 1
    powershell_register_script "$history_file"
    printf '%s' "$history_file"
}

# Generates a small startup script that maps the mount to a drive letter and
# moves the prompt there. Kept separate from the user's real PowerShell profile.
powershell_write_profile() {
    local drive="$VED_WINDOWS_DRIVE"
    local root="$VED_WINDOWS_MOUNT"
    local script_dir
    local profile

    script_dir="$(powershell_script_dir)"
    profile="$script_dir/ved-profile.ps1"

    cat >"$profile" <<PS1
\$ErrorActionPreference = 'Continue'
\$vedHistory = '$script_dir/PSReadLine_history.txt'
try {
    if (Get-Command -Name Set-PSReadLineOption -ErrorAction SilentlyContinue) {
        Set-PSReadLineOption -HistorySavePath \$vedHistory -ErrorAction Stop
    }
} catch {
    # History is optional; never let it break the shell.
}
\$vedRoot = '$root'
if (-not (Test-Path -LiteralPath \$vedRoot)) {
    Write-Warning "Windows mount not found: \$vedRoot"
} else {
    if (-not (Get-PSDrive -Name '$drive' -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name '$drive' -PSProvider FileSystem -Root \$vedRoot | Out-Null
    }
    Set-Location '${drive}:\'
}
function global:prompt { 'PS ${drive}:\> ' }
PS1

    powershell_register_script "$profile"
    printf '%s' "$profile"
}

powershell_run_pwsh() {
    local profile="$1" command="$2" script="" binary script_dir
    local -a pwsh_args=(-NoLogo -NoProfile)
    local -a runner=()

    script_dir="$(powershell_script_dir)"

    binary="$(powershell_binary)" || powershell_fail_missing

    if [[ -n "${VED_GUI_USER:-}" ]]; then
        runner=(
            runuser -u "$VED_GUI_USER" -- env
            "HOME=$VED_GUI_HOME"
            "USER=$VED_GUI_USER"
            "LOGNAME=$VED_GUI_USER"
            "TERM=${TERM:-xterm-256color}"
            "PATH=${PATH:-/usr/local/bin:/usr/bin:/bin}"
            "LANG=${LANG:-C.UTF-8}"
        )
    fi

    if [[ -n "$command" ]]; then
        script="$script_dir/ved-command.ps1"
        {
            printf ". '%s'\n" "$profile"
            printf '%s\n' "$command"
        } >"$script"
        powershell_register_script "$script"
        pwsh_args+=(-File "$script")
    else
        pwsh_args+=(-NoExit -File "$profile")
    fi

    if [[ "$VED_DRY_RUN" -eq 1 ]]; then
        info "$(t dry_run)"
        print_command "${runner[@]}" "$binary" "${pwsh_args[@]}"
        printf '\n'
        return 0
    fi

    info "$(t powershell_profile "$VED_WINDOWS_DRIVE")"
    if [[ -n "$command" ]]; then
        info "$(t powershell_command "$command")"
    else
        info "$(t powershell_shell)"
    fi

    "${runner[@]}" "$binary" "${pwsh_args[@]}"
}

powershell_run_cmd() {
    local command="$1"
    local prefix="${VED_GUI_HOME:-/root}/.local/share/ved/wine"
    local uid="${VED_GUI_UID:-0}" gid="${VED_GUI_GID:-0}"
    local -a runner=()
    local -a wine_command=(wine cmd.exe)

    [[ -n "${VED_GUI_USER:-}" ]] || die "$(t wine_needs_user)"

    runner=(
        runuser -u "$VED_GUI_USER" -- env
        "HOME=$VED_GUI_HOME"
        "USER=$VED_GUI_USER"
        "LOGNAME=$VED_GUI_USER"
        "TERM=${TERM:-xterm-256color}"
        "PATH=${PATH:-/usr/local/bin:/usr/bin:/bin}"
        "WINEPREFIX=$prefix"
        "WINEDEBUG=-all"
        "WINEDLLOVERRIDES=mscoree,mshtml="
    )

    if [[ -n "$command" ]]; then
        wine_command+=(/c "$command")
    fi

    if [[ "$VED_DRY_RUN" -eq 1 ]]; then
        info "$(t dry_run)"
        print_command "${runner[@]}" wineboot -u
        printf '\n'
        print_command "${runner[@]}" "${wine_command[@]}"
        printf '\n'
        return 0
    fi

    install -d -m 700 -o "$uid" -g "${gid:-$uid}" "$prefix" ||
        die "$(t wine_prefix_failed)"
    timeout 90 "${runner[@]}" wineboot -u >/dev/null 2>&1 ||
        warn "$(t wine_prefix_failed)"

    # Wine's own C: stays intact; the Windows partition is exposed as W:.
    ln -sfn "$VED_WINDOWS_MOUNT" "$prefix/dosdevices/w:" ||
        die "$(t wine_prefix_failed)"

    if [[ -n "$command" ]]; then
        info "$(t cmd_command "$command")"
    else
        info "$(t cmd_shell)"
    fi

    "${runner[@]}" "${wine_command[@]}"
}

backend_powershell() {
    local profile command="${VED_COMMAND:-}" mount_dir script_dir dir

    detect_graphical_user_optional

    if [[ "$VED_SHELL" == "pwsh" ]]; then
        powershell_binary >/dev/null 2>&1 || powershell_fail_missing
    fi

    if [[ -n "$VED_ROOT_PARTITION" ]]; then
        [[ -b "$VED_ROOT_PARTITION" ]] ||
            die "$(t partition_missing "$VED_ROOT_PARTITION")"
    else
        select_disk
        detect_windows_partition
    fi

    if [[ "$VED_WINDOWS_WRITE" -eq 1 ]]; then
        warn "$(t windows_writable_warning)"
    fi

    show_configuration

    # The private run directory is root-only. Put both the mount and the
    # generated .ps1 files somewhere the unprivileged shell user can traverse.
    # The script directory must be separate from the mountpoint: mounting on
    # top of it would hide anything written there before the mount.
    mount_dir="$(make_temp_dir "${TMPDIR:-/tmp}/ved-windows.XXXXXX")"
    script_dir="$(make_temp_dir "${TMPDIR:-/tmp}/ved-shell.XXXXXX")"

    if [[ -n "${VED_GUI_UID:-}" && "${VED_GUI_UID}" != "0" ]]; then
        for dir in "$mount_dir" "$script_dir"; do
            chown "$VED_GUI_UID:${VED_GUI_GID:-$VED_GUI_UID}" "$dir" ||
                die "$(t windows_temp_failed "$dir")"
        done
    fi
    VED_WINDOWS_SCRIPT_DIR="$script_dir"
    powershell_prepare_history >/dev/null ||
        die "$(t windows_temp_failed "$script_dir")"

    powershell_mount_partition "$VED_ROOT_PARTITION" "$mount_dir"
    VED_WINDOWS_MOUNT="${VED_WINDOWS_MOUNT:-$mount_dir}"

    profile="$(powershell_write_profile)"

    if [[ "$VED_SHELL" == "cmd" ]]; then
        powershell_run_cmd "$command"
    else
        powershell_run_pwsh "$profile" "$command"
    fi
}
