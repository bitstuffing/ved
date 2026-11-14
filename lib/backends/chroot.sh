chroot_bind() {
    local source="$1"
    local target="$2"
    local recursion="${3:-rbind}"

    [[ -e "$source" || -S "$source" ]] || return 0

    if [[ ! -d "$source" ]]; then
        mkdir -p "$(dirname "$target")"
        [[ -e "$target" || -S "$target" ]] || : >"$target"
    else
        mkdir -p "$target"
    fi

    if mountpoint -q "$target" 2>/dev/null; then
        return 0
    fi

    if mount "--$recursion" "$source" "$target" 2>/dev/null; then
        mount --make-rslave "$target" 2>/dev/null || true
        cleanup_add_mount "$target"
        return 0
    fi

    warn "$(t chroot_bind_failed "$source")"
    return 1
}

chroot_prepare_mounts() {
    local root="$1"
    local directory

    for directory in dev proc sys; do
        chroot_bind "/$directory" "$root/$directory" rbind || true
    done

    if [[ "$VED_GRAPHICAL" -eq 1 && -n "${VED_HOST_RUNTIME_DIR:-}" &&
        -n "${VED_GUEST_RUNTIME:-}" ]]; then
        chroot_bind "$VED_HOST_RUNTIME_DIR" "$root$VED_GUEST_RUNTIME" rbind || true
    fi
    if [[ -d /run/dbus ]]; then
        chroot_bind "/run/dbus" "$root/run/dbus" rbind || true
    fi
    if [[ -d /run/systemd/resolve ]]; then
        chroot_bind "/run/systemd/resolve" "$root/run/systemd/resolve" rbind || true
    fi

    if [[ -d /tmp/.X11-unix ]]; then
        chroot_bind "/tmp/.X11-unix" "$root/tmp/.X11-unix" rbind || true
    fi

    if [[ -d /dev/dri ]]; then
        chroot_bind "/dev/dri" "$root/dev/dri" rbind || true
    fi
    if [[ -d /dev/snd ]]; then
        chroot_bind "/dev/snd" "$root/dev/snd" rbind || true
    fi
    if [[ -d /dev/input ]]; then
        chroot_bind "/dev/input" "$root/dev/input" rbind || true
    fi

    if [[ -f /etc/resolv.conf && -d "$root/etc" ]]; then
        if [[ ! -L "$root/etc/resolv.conf" ]]; then
            chroot_bind "/etc/resolv.conf" "$root/etc/resolv.conf" bind || true
        fi
    fi

    if [[ "$VED_GRAPHICAL" -eq 1 && -n "${XAUTHORITY:-}" &&
        -f "${XAUTHORITY:-}" ]]; then
        if chroot_bind "$XAUTHORITY" "$root/tmp/.host-Xauthority" bind; then
            VED_GUEST_XAUTHORITY="/tmp/.host-Xauthority"
        fi
    fi
}

chroot_detect_user() {
    local root="$1"
    local user=""

    if [[ -n "$VED_USER" ]]; then
        printf '%s' "$VED_USER"
        return
    fi

    if [[ -r "$root/etc/passwd" ]]; then
        if [[ "$VED_GRAPHICAL" -eq 1 && -n "${VED_GUI_UID:-}" ]]; then
            user="$(awk -F: -v uid="$VED_GUI_UID" \
                '$3 == uid {print $1; exit}' "$root/etc/passwd")"
        fi
        if [[ -z "$user" ]]; then
            user="$(awk -F: '$3 == 1000 {print $1; exit}' "$root/etc/passwd")"
        fi
    fi

    printf '%s' "$user"
}

chroot_apply_user_ids() {
    local root="$1"
    local user="$2"
    local uid=""
    local gid=""

    VED_GUEST_UID="${VED_GUI_UID:-}"
    VED_GUEST_GID="${VED_GUI_GID:-}"

    if [[ -n "$user" && -r "$root/etc/passwd" ]]; then
        uid="$(awk -F: -v u="$user" '$1 == u {print $3; exit}' "$root/etc/passwd")"
        gid="$(awk -F: -v u="$user" '$1 == u {print $4; exit}' "$root/etc/passwd")"
        [[ -n "$uid" ]] && VED_GUEST_UID="$uid"
        [[ -n "$gid" ]] && VED_GUEST_GID="$gid"
    fi

    if [[ "$VED_GUI_TARGET" != "nested" && -n "${VED_GUI_UID:-}" &&
        "$VED_GUEST_UID" != "$VED_GUI_UID" ]]; then
        warn "$(t guest_uid_mismatch "$VED_GUEST_UID" "$VED_GUI_UID")"
    fi
}

chroot_shell_for() {
    local root="$1"
    local user="$2"
    local shell=""

    if [[ -n "$user" && -r "$root/etc/passwd" ]]; then
        shell="$(awk -F: -v u="$user" '$1 == u {print $7; exit}' "$root/etc/passwd")"
    fi

    if [[ -z "$shell" || ! -x "$root$shell" ]]; then
        if [[ -x "$root/bin/bash" ]]; then
            shell="/bin/bash"
        else
            shell="/bin/sh"
        fi
    fi

    printf '%s' "$shell"
}

chroot_run() {
    local root="$1"
    local user="$2"
    local command="$3"
    local shell
    local user_spec="$user"
    local passwd_spec=""
    local env_bin="/usr/bin/env"
    local -a chroot_command=()
    local -a env_command=()
    local runtime="${VED_GUEST_RUNTIME:-}"

    shell="$(chroot_shell_for "$root" "$user")"

    if [[ ! -x "$root/usr/bin/env" && -x "$root/bin/env" ]]; then
        env_bin="/bin/env"
    fi

    if [[ -n "$user" && "$user" != "root" && -r "$root/etc/passwd" ]]; then
        passwd_spec="$(awk -F: -v u="$user" '$1 == u {print $3 ":" $4; exit}' "$root/etc/passwd")"
        if [[ -n "$passwd_spec" ]]; then
            user_spec="$passwd_spec"
        fi
    fi

    chroot_command=(chroot)
    if [[ -n "$user" ]]; then
        chroot_command+=("--userspec=$user_spec")
    fi
    chroot_command+=("$root")

    env_command=(
        "$env_bin"
        "HOME=/root"
        "USER=root"
        "LOGNAME=root"
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        "TERM=${TERM:-xterm-256color}"
        "LANG=${LANG:-C.UTF-8}"
    )

    if [[ -n "$user" ]]; then
        env_command=(
            "$env_bin"
            "HOME=$(awk -F: -v u="$user" '$1 == u {print $6; exit}' "$root/etc/passwd" 2>/dev/null)"
            "USER=$user"
            "LOGNAME=$user"
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            "TERM=${TERM:-xterm-256color}"
            "LANG=${LANG:-C.UTF-8}"
        )
    fi

    if [[ "$VED_GRAPHICAL" -eq 1 ]] && [[ -n "$runtime" ]]; then
        local guest_display
        guest_display="$(guest_display_value)"
        env_command+=(
            "DISPLAY=$guest_display"
            "XDG_RUNTIME_DIR=$runtime"
            "XAUTHORITY=${VED_GUEST_XAUTHORITY:-${XAUTHORITY:-$VED_GUI_HOME/.Xauthority}}"
            "XDG_SESSION_DESKTOP=${XDG_SESSION_DESKTOP:-}"
            "XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-}"
            "XDG_SESSION_CLASS=user"
            "XDG_VTNR=${XDG_VTNR:-}"
        )
        if [[ "$VED_GUI_TARGET" == "nested" ]]; then
            env_command+=(
                "WAYLAND_DISPLAY="
                "XDG_SESSION_TYPE=x11"
                "LIBGL_ALWAYS_SOFTWARE=1"
            )
        else
            env_command+=(
                "WAYLAND_DISPLAY=${VED_GUEST_WAYLAND_DISPLAY:-${WAYLAND_DISPLAY:-}}"
                "XDG_SESSION_TYPE=${VED_GUI_SESSION_TYPE:-${XDG_SESSION_TYPE:-wayland}}"
            )
        fi
    fi

    if [[ -n "$command" ]]; then
        chroot_command+=("${env_command[@]}" /bin/sh -c "$command")
    else
        chroot_command+=("${env_command[@]}" "$shell")
    fi

    if [[ "$VED_DRY_RUN" -eq 1 ]]; then
        info "$(t dry_run)"
        print_command "${chroot_command[@]}"
        printf '\n'
        return 0
    fi

    "${chroot_command[@]}"
}

backend_chroot() {
    local root="$VED_CHROOT_DIR"
    local user
    local command=""

    if [[ -n "$VED_ROOT_PARTITION" ]]; then
        [[ -b "$VED_ROOT_PARTITION" ]] ||
            die "$(t partition_missing "$VED_ROOT_PARTITION")"
        assert_unmounted "$VED_ROOT_PARTITION"
    else
        select_disk
        assert_unmounted "$VED_DISK"
        detect_root_partition
    fi

    select_session

    if [[ "$VED_SESSION" == "system" ]]; then
        if have systemd-nspawn; then
            info "$(t system_using_nspawn)"
            VED_BOOT=1
            backend_nspawn
            return
        fi
        die "$(t system_needs_nspawn)"
    fi

    if session_is_graphical; then
        VED_GRAPHICAL=1
    fi

    if [[ "$VED_GRAPHICAL" -eq 1 ]]; then
        detect_graphical_user
        if session_is_graphical; then
            if [[ "$VED_SESSION" == "app" && -z "$VED_COMMAND" && -t 0 ]]; then
                VED_COMMAND="$(ask "$(t app_command_prompt)" "")"
            fi
            select_gui_target
            if [[ "$VED_GUI_TARGET" == "nested" ]]; then
                gui_start_nested || true
            fi
        fi
    fi

    show_configuration

    info "$(t chroot_mounting)"
    mkdir -p "$root"
    cleanup_add_dir "$root"
    umount_path "$root"
    mount_path "$VED_ROOT_PARTITION" "$root" "rw"
    info "$(t chroot_ready "$root")"

    user="$(chroot_detect_user "$root")"
    if [[ -z "$user" ]]; then
        user="root"
        warn "$(t chroot_no_user)"
    fi

    if [[ "$VED_GRAPHICAL" -eq 1 ]]; then
        chroot_apply_user_ids "$root" "$user"
        prepare_graphical_runtime
    fi

    chroot_prepare_mounts "$root"

    if session_is_graphical; then
        command="$(session_build_command "$root" || true)"
        if [[ -z "$command" ]]; then
            if [[ "$VED_SESSION" == "desktop" ]]; then
                warn "$(t desktop_session_missing)"
            else
                warn "$(t app_command_missing)"
            fi
            VED_SESSION="shell"
        fi
    fi

    if [[ -z "$command" ]]; then
        command="$VED_COMMAND"
    fi

    if [[ "$VED_GRAPHICAL" -eq 1 ]]; then
        info "$(t chroot_graphical)"
    fi

    if [[ -n "$command" ]]; then
        info "$(t chroot_command "$command")"
    else
        info "$(t chroot_entering "$user")"
        info "$(t chroot_shell)"
    fi

    chroot_run "$root" "$user" "$command"
}
