nspawn_user_home() {
    local root="$1"
    local user="$2"

    if [[ -z "$user" || ! -r "$root/etc/passwd" ]]; then
        printf '%s' "/root"
        return
    fi

    awk -F: -v u="$user" '$1 == u {print $6; exit}' "$root/etc/passwd"
}

nspawn_prepare_graphical_bus() {
    local root="$1"
    local guest_bus_dir=""

    VED_GUEST_SYSTEM_BUS_ADDRESS=""
    VED_NSPAWN_GUEST_BUS_DIR=""
    [[ "$VED_GRAPHICAL" -eq 1 && "$VED_BOOT" -ne 1 ]] || return 0

    [[ -n "${VED_RUN_DIR:-}" ]] || return 1
    guest_bus_dir="$VED_RUN_DIR/nspawn-guest-dbus"
    VED_NSPAWN_GUEST_BUS_DIR="$guest_bus_dir"

    # A dry run has no real container; publish the intended command only.
    if [[ "$VED_DRY_RUN" -eq 1 ]]; then
        VED_GUEST_SYSTEM_BUS_ADDRESS="unix:path=/run/dbus/system_bus_socket"
        return 0
    fi

    install -d -m 755 "$guest_bus_dir" 2>/dev/null || return 1
    cleanup_add_dir "$guest_bus_dir"

    # nspawn mounts its own tmpfs on /run, hiding this mount. We still need it
    # here so chroot_start_system_bus() can start the daemon against the guest
    # configuration; nspawn_build_args() binds the same directory again inside
    # the container's private /run.
    chroot_bind "$guest_bus_dir" "$root/run/dbus" rbind || return 1
    if chroot_start_system_bus "$root"; then
        VED_GUEST_SYSTEM_BUS_ADDRESS="unix:path=/run/dbus/system_bus_socket"
        return 0
    fi

    warn "$(t guest_system_bus_failed)"
    umount "$root/run/dbus" 2>/dev/null || true
    VED_GUEST_SYSTEM_BUS_ADDRESS=""
    VED_NSPAWN_GUEST_BUS_DIR=""
    return 1
}

nspawn_build_args() {
    local root="$1"
    local user="$2"
    local command="$3"
    local shell
    local env_bin=""
    local runtime="${VED_GUEST_RUNTIME:-}"
    local home
    local wayland_env=""
    local machine_base="${VED_DISK:-$root}"
    local guest_hostname_value=""

    machine_base="${machine_base##*/}"
    machine_base="${machine_base//[^A-Za-z0-9]/-}"
    NSPAWN_ARGS=(-D "$root")
    VED_NSPAWN_MACHINE_NAME="ved-${machine_base:-root}-$$"
    NSPAWN_ARGS+=(--machine="$VED_NSPAWN_MACHINE_NAME")

    guest_hostname_value="$(guest_hostname "$root" 2>/dev/null || true)"
    if [[ -n "$guest_hostname_value" ]]; then
        NSPAWN_ARGS+=(--hostname="$guest_hostname_value")
    fi

    if [[ "$VED_GRAPHICAL" -eq 1 && "$VED_BOOT" -ne 1 ]]; then
        # GNOME Keyring needs mlock in FIPS mode. --rlimit sets the limit for
        # the container payload itself, even when the invoking shell lacks
        # CAP_SYS_RESOURCE and cannot raise its own hard limit.
        NSPAWN_ARGS+=(--rlimit=MEMLOCK=infinity)
        # nspawn replaces /run with a private tmpfs, so the --bind below is
        # required even though the same directory was mounted during setup.
        if [[ -n "$VED_NSPAWN_GUEST_BUS_DIR" ]]; then
            NSPAWN_ARGS+=("--bind=$VED_NSPAWN_GUEST_BUS_DIR:/run/dbus")
        fi
        # /dev/null masks the guest's libgcrypt FIPS force file; the original
        # remains intact underneath because this is a read-only bind.
        NSPAWN_ARGS+=(--bind-ro=/dev/null:/etc/gcrypt/fips_enabled)
    fi

    if [[ -n "$user" && "$VED_BOOT" -ne 1 ]]; then
        NSPAWN_ARGS+=(--user="$user")
    fi

    if [[ "$VED_GRAPHICAL" -eq 1 ]] && [[ -n "$runtime" ]]; then
        home="$(nspawn_user_home "$root" "$user")"

        if [[ -n "${VED_HOST_RUNTIME_DIR:-}" && -d "$VED_HOST_RUNTIME_DIR" ]]; then
            NSPAWN_ARGS+=(--bind="$VED_HOST_RUNTIME_DIR:$runtime")
        fi
        if [[ -d /tmp/.X11-unix ]]; then
            NSPAWN_ARGS+=(--bind=/tmp/.X11-unix)
        fi
        if [[ -d /dev/dri ]]; then
            NSPAWN_ARGS+=(--bind=/dev/dri "--property=DeviceAllow=char-drm rw")
        fi
        if [[ -d /dev/snd ]]; then
            NSPAWN_ARGS+=(--bind=/dev/snd)
        fi
        # Graphical non-boot containers get their own private system bus;
        # only plain shells/containers share the host bus.
        if [[ "$VED_BOOT" -ne 1 && "$VED_GRAPHICAL" -ne 1 && -d /run/dbus ]]; then
            NSPAWN_ARGS+=(--bind=/run/dbus)
        fi

        local xauthority="${XAUTHORITY:-$VED_GUI_HOME/.Xauthority}"
        if [[ -f "$xauthority" ]]; then
            NSPAWN_ARGS+=(--bind-ro="$xauthority")
        fi

        local guest_display
        guest_display="$(guest_display_value)"
        if [[ "${VED_WAYLAND_EXPORT_FAILED:-0}" -eq 1 ]]; then
            wayland_env=""
        else
            wayland_env="${VED_GUEST_WAYLAND_DISPLAY:-${WAYLAND_DISPLAY:-}}"
        fi

        NSPAWN_ARGS+=(
            "--setenv=DISPLAY=$guest_display"
            "--setenv=XDG_RUNTIME_DIR=$runtime"
            "--setenv=XAUTHORITY=$xauthority"
            "--setenv=HOME=$home"
            "--setenv=USER=${user:-root}"
            "--setenv=LOGNAME=${user:-root}"
            "--setenv=XDG_SESSION_DESKTOP=${VED_GUEST_SESSION_DESKTOP:-}"
            "--setenv=XDG_CURRENT_DESKTOP=${VED_GUEST_CURRENT_DESKTOP:-}"
            "--setenv=XDG_SESSION_CLASS=user"
            "--setenv=XDG_VTNR=${XDG_VTNR:-}"
        )
        if [[ -n "$guest_hostname_value" ]]; then
            NSPAWN_ARGS+=("--setenv=HOSTNAME=$guest_hostname_value")
        fi

        if [[ "$VED_GUI_TARGET" == "nested" ]]; then
            NSPAWN_ARGS+=(
                "--setenv=WAYLAND_DISPLAY="
                "--setenv=XDG_SESSION_TYPE=x11"
                "--setenv=LIBGL_ALWAYS_SOFTWARE=1"
            )
        else
            NSPAWN_ARGS+=(
                "--setenv=WAYLAND_DISPLAY=$wayland_env"
                "--setenv=XDG_SESSION_TYPE=${VED_GUEST_SESSION_TYPE:-${VED_GUI_SESSION_TYPE:-${XDG_SESSION_TYPE:-wayland}}}"
            )
        fi

        if [[ -d /dev/input ]]; then
            NSPAWN_ARGS+=(--bind=/dev/input)
        fi
    fi

    if [[ -n "${VED_GUEST_SYSTEM_BUS_ADDRESS:-}" ]]; then
        NSPAWN_ARGS+=("--setenv=DBUS_SYSTEM_BUS_ADDRESS=$VED_GUEST_SYSTEM_BUS_ADDRESS")
    fi

    if [[ "$VED_BOOT" -eq 1 ]]; then
        NSPAWN_ARGS+=(--boot)
        return
    fi

    shell="$(chroot_shell_for "$root" "${user:-root}")"

    for path in /usr/bin/env /bin/env; do
        if [[ -x "$root$path" ]]; then
            env_bin="$path"
            break
        fi
    done

    if [[ -n "$command" ]]; then
        if [[ -n "$env_bin" ]]; then
            NSPAWN_ARGS+=(-- "$env_bin" -u LIBGCRYPT_FORCE_FIPS_MODE \
                /bin/sh -c "$command")
        else
            NSPAWN_ARGS+=(-- /bin/sh -c "$command")
        fi
    elif [[ -n "$env_bin" ]]; then
        NSPAWN_ARGS+=(-- "$env_bin" -u LIBGCRYPT_FORCE_FIPS_MODE "$shell")
    else
        NSPAWN_ARGS+=(-- "$shell")
    fi
}

nspawn_status_bar_init() {
    [[ -t 1 ]] || return 1
    [[ "$VED_BOOT" -eq 1 ]] || return 1

    VED_NSPAWN_PID=""
    VED_NSPAWN_IN_COMMAND_MODE=0

    tput civis 2>/dev/null
    nspawn_status_bar_draw
    # Do not change the terminal mode here: systemd-nspawn uses the same tty
    # for the container console and needs to receive Ctrl-] itself.
    return 0
}

nspawn_status_bar_draw() {
    local cols
    cols="$(tput cols 2>/dev/null || printf '80')"
    local hint
    if [[ "$VED_NSPAWN_IN_COMMAND_MODE" -eq 1 ]]; then
        hint="$(t nspawn_status_hint_cmd)"
    else
        hint="$(t nspawn_status_hint)"
    fi
    local status
    status="$(t nspawn_status_machine "$VED_NSPAWN_MACHINE_NAME" "${VED_NSPAWN_PID:-starting...}")"
    local bar="${status}${hint}"
    if (( ${#bar} > cols )); then
        bar="${bar:0:$cols}"
    fi
    tput sc 2>/dev/null
    tput cup $((LINES - 1)) 0 2>/dev/null
    printf '\r%s\e[K' "$bar"
    tput rc 2>/dev/null
}

nspawn_status_bar_update_pid() {
    VED_NSPAWN_PID="$1"
    nspawn_status_bar_draw
}

nspawn_status_bar_cleanup() {
    [[ -t 1 ]] || return
    tput cnorm 2>/dev/null
    tput cup $((LINES - 1)) 0 2>/dev/null
    printf '\e[K\n'
}

nspawn_stop_container() {
    local machine="$1"
    info "$(t nspawn_stopping "$machine")"
    machinectl terminate "$machine" 2>/dev/null || true
    local i
    for i in {1..30}; do
        if ! machinectl list --no-legend 2>/dev/null | grep -q "^$machine "; then
            break
        fi
        sleep 0.5
    done
}

nspawn_reboot_container() {
    local machine="$1"
    info "$(t nspawn_rebooting "$machine")"
    machinectl reboot "$machine" 2>/dev/null || true
}

nspawn_poweroff_container() {
    local machine="$1"
    info "$(t nspawn_powering_off "$machine")"
    machinectl poweroff "$machine" 2>/dev/null || true
}

nspawn_wait_loop() {
    local nspawn_pid="$1"

    nspawn_status_bar_update_pid "$nspawn_pid"

    # Only poll the PID. Reading from stdin here used to swallow the Ctrl-]
    # sequence that systemd-nspawn needs for a clean detach/shutdown.
    while kill -0 "$nspawn_pid" 2>/dev/null; do
        nspawn_status_bar_draw
        sleep 0.5
    done

    wait "$nspawn_pid" 2>/dev/null || true
    nspawn_status_bar_cleanup
}

backend_nspawn() {
    local root="$VED_CHROOT_DIR"
    local user
    local command=""

    have systemd-nspawn || die "$(t nspawn_missing)"

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
        VED_BOOT=1
    fi

    if session_is_graphical; then
        VED_GRAPHICAL=1
    fi

    # fix: mount before the graphical questions to be able to inspect the guest
    info "$(t chroot_mounting)"
    mkdir -p "$root"
    cleanup_add_dir "$root"
    umount_path "$root"
    mount_linux_root "$VED_ROOT_PARTITION" "$root" "rw"
    info "$(t chroot_ready "$root")"

    if [[ "$VED_GRAPHICAL" -eq 1 ]]; then
        detect_graphical_user
        session_probe_guest "$root"
        info "$(t nspawn_graphical)"

        if session_is_graphical; then
            if [[ "$VED_SESSION" == "desktop" &&
                  -z "$VED_COMMAND" ]]; then
                select_desktop_session "$root" ||
                    die "$(t desktop_session_missing)"
            fi

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

    if [[ ! -d "$root/etc/systemd/system" && ! -x "$root/usr/lib/systemd/systemd" && ! -x "$root/lib/systemd/systemd" ]]; then
        warn "$(t nspawn_requires_systemd)"
    fi

    user="$(chroot_detect_user "$root")"
    if [[ -z "$user" ]]; then
        user="root"
    fi

    if [[ "$VED_GRAPHICAL" -eq 1 ]]; then
        chroot_apply_user_ids "$root" "$user"
        prepare_graphical_runtime
        nspawn_prepare_graphical_bus "$root" || true
        prepare_guest_nonfips_config "$root" >/dev/null || true
    fi

    if session_is_graphical; then
        command="$(session_build_command_ex "$root" || true)"
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

    ensure_guest_desktop_identity "$command"

    if [[ "$VED_BOOT" -eq 1 ]]; then
        info "$(t nspawn_boot)"
    elif [[ -n "$command" ]]; then
        info "$(t nspawn_command "$command")"
    else
        info "$(t nspawn_shell)"
    fi

    nspawn_build_args "$root" "$user" "$command"

    if [[ "$VED_DRY_RUN" -eq 1 ]]; then
        info "$(t dry_run)"
        print_command systemd-nspawn "${NSPAWN_ARGS[@]}"
        printf '\n'
        return 0
    fi

    if [[ "$VED_GRAPHICAL" -eq 1 ]]; then
        raise_graphical_memlock_limit || true
    fi

    info "$(t nspawn_starting)"

    if [[ "$VED_BOOT" -eq 1 ]]; then
        systemd-nspawn "${NSPAWN_ARGS[@]}" &
        local nspawn_pid=$!
        cleanup_add_pid "$nspawn_pid"

        if nspawn_status_bar_init; then
            nspawn_wait_loop "$nspawn_pid"
        else
            wait "$nspawn_pid"
        fi
    else
        systemd-nspawn "${NSPAWN_ARGS[@]}"
    fi
}
