session_is_graphical() {
    [[ "$VED_SESSION" == "app" || "$VED_SESSION" == "desktop" ]]
}

select_session() {
    local option

    if [[ "$VED_SESSION_SET" -eq 1 || "$VED_SESSION" != "auto" ]]; then
        return
    fi

    if [[ "$VED_GRAPHICAL" -eq 1 ]]; then
        VED_SESSION="shell"
        return
    fi

    if [[ ! -t 0 ]]; then
        VED_SESSION="shell"
        return
    fi

    echo
    info "$(t select_session)"
    printf '  1) %s\n' "$(t session_shell)"
    printf '  2) %s\n' "$(t session_app)"
    printf '  3) %s\n' "$(t session_desktop)"
    printf '  4) %s\n' "$(t session_system)"
    echo

    option="$(ask "$(t select_session_prompt)" "1")"
    case "$option" in
        1) VED_SESSION="shell" ;;
        2) VED_SESSION="app" ;;
        3) VED_SESSION="desktop" ;;
        4) VED_SESSION="system" ;;
        *) die "$(t invalid_option)" ;;
    esac
    VED_SESSION_SET=1
}

select_gui_target() {
    local option

    if [[ "$VED_GUI_TARGET" != "auto" ]]; then
        return
    fi

    if [[ ! -t 0 ]]; then
        VED_GUI_TARGET="host"
        return
    fi

    echo
    info "$(t select_gui_target)"
    printf '  1) %s\n' "$(t gui_target_host)"
    printf '  2) %s\n' "$(t gui_target_nested)"
    echo

    option="$(ask "$(t select_gui_target_prompt)" "1")"
    case "$option" in
        1) VED_GUI_TARGET="host" ;;
        2) VED_GUI_TARGET="nested" ;;
        *) die "$(t invalid_option)" ;;
    esac
}

select_arch() {
    local option

    if [[ "$VED_ARCH" != "auto" ]]; then
        return
    fi

    if [[ ! -t 0 ]]; then
        return
    fi

    echo
    info "$(t select_arch)"
    printf '  1) %s\n' "$(t arch_x86_64)"
    printf '  2) %s\n' "$(t arch_aarch64)"
    printf '  3) %s\n' "$(t arch_auto)"
    echo

    option="$(ask "$(t select_arch_prompt)" "1")"
    case "$option" in
        1) VED_ARCH="x86_64" ;;
        2) VED_ARCH="aarch64" ;;
        3) VED_ARCH="auto" ;;
        *) die "$(t invalid_option)" ;;
    esac
}

gui_runtime_export_socket() {
    local source="$1"
    local target="$2"

    [[ -e "$source" || -S "$source" ]] || return 0
    mkdir -p "$(dirname "$target")"
    cleanup_add_dir "$(dirname "$target")"
    if [[ ! -e "$target" && ! -S "$target" ]]; then
        : >"$target"
        cleanup_add_file "$target"
    fi

    if mountpoint -q "$target" 2>/dev/null; then
        return 0
    fi

    if mount --bind "$source" "$target" 2>/dev/null; then
        cleanup_add_mount "$target"
        return 0
    fi

    return 1
}

prepare_graphical_runtime() {
    local runtime
    local wayland_source
    local uid="${VED_GUEST_UID:-${VED_GUI_UID:-}}"
    local gid="${VED_GUEST_GID:-${VED_GUI_GID:-}}"

    [[ "$VED_GRAPHICAL" -eq 1 ]] || return 0
    [[ -n "$uid" ]] || return 0

    # Never reuse the host's /run/user/$UID. It belongs to the host's systemd
    # user manager and holds the live keyring, gvfs, PipeWire and D-Bus
    # sockets. Sharing it makes the guest daemons collide with the host ones.
    VED_GUEST_RUNTIME="/run/user/$uid"
    runtime="/run/ved/runtime-$uid-$$"

    rm -rf -- "$runtime"
    install -d -m 700 -o "$uid" -g "${gid:-$uid}" "$runtime" ||
        die "$(t runtime_prepare_failed "$runtime")"
    cleanup_add_dir "$runtime"
    VED_HOST_RUNTIME_DIR="$runtime"

    # Audio sockets are safe to share: they are plain Unix sockets, not
    # daemon-owned lock files.
    gui_runtime_export_socket "$VED_GUI_RUNTIME/pulse/native" \
        "$runtime/pulse/native" || true
    gui_runtime_export_socket "$VED_GUI_RUNTIME/pipewire-0" \
        "$runtime/pipewire-0" || true

    # The host Wayland compositor socket is only needed when drawing on the
    # host display. With Xephyr, DISPLAY points at the nested X server instead.
    if [[ "$VED_GUI_TARGET" != "nested" && -n "${WAYLAND_DISPLAY:-}" ]]; then
        wayland_source="$VED_GUI_RUNTIME/$WAYLAND_DISPLAY"
        if [[ "$WAYLAND_DISPLAY" == /* ]]; then
            wayland_source="$WAYLAND_DISPLAY"
        fi
        if [[ -e "$wayland_source" || -S "$wayland_source" ]] &&
            gui_runtime_export_socket "$wayland_source" \
                "$runtime/${wayland_source##*/}"; then
            VED_GUEST_WAYLAND_DISPLAY="${wayland_source##*/}"
        elif [[ "$VED_GUI_SESSION_TYPE" == "wayland" ]]; then
            # No wayland socket: fall back to the host's XWayland/X11 socket.
            VED_GUI_SESSION_TYPE="x11"
        fi
    fi
}

detect_desktop_session() {
    local root="$1"
    local candidate
    local -a candidates=(
        startplasma-x11 startplasma-wayland
        gnome-session gnome-xorg
        startxfce4 xfce4-session
        mate-session cinnamon-session
        lxqt-session startlxde lxsession
        budgie-desktop
        sway i3 openbox-session
    )

    for candidate in "${candidates[@]}"; do
        if [[ -x "$root/usr/bin/$candidate" || -x "$root/bin/$candidate" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

session_build_command() {
    local root="$1"
    local command=""
    local user_manager=""

    case "$VED_SESSION" in
        desktop)
            command="$VED_COMMAND"
            if [[ -z "$command" ]]; then
                command="$(detect_desktop_session "$root" || true)"
            fi
            if [[ -z "$command" ]]; then
                return 1
            fi

            # systemd-run --user only works when a systemd *user* manager is
            # running inside the container. A container started without
            # --boot has no PID 1 and therefore no user manager; the only
            # systemd socket visible there would be the host's, which cannot
            # launch guest binaries.
            if [[ -n "${VED_GUEST_RUNTIME:-}" ]]; then
                user_manager="$root$VED_GUEST_RUNTIME/systemd/private"
            fi

            if [[ "$VED_BACKEND" == "nspawn" && -S "$user_manager" &&
                ( -x "$root/usr/bin/systemd-run" || -x "$root/bin/systemd-run" ) ]]; then
                command="systemd-run --user --scope -- $command"
            elif [[ -x "$root/usr/bin/dbus-run-session" || -x "$root/bin/dbus-run-session" ]]; then
                command="dbus-run-session -- $command"
            fi
            ;;
        *)
            command="$VED_COMMAND"
            ;;
    esac

    printf '%s' "$command"
}

guest_display_value() {
    if [[ "$VED_GUI_TARGET" == "nested" && -n "$VED_NESTED_DISPLAY" ]]; then
        printf '%s' "$VED_NESTED_DISPLAY"
    else
        printf '%s' "${DISPLAY:-:0}"
    fi
}

gui_start_nested() {
    local n display attempt

    if ! have Xephyr; then
        warn "$(t nested_unavailable)"
        VED_GUI_TARGET="host"
        return 1
    fi

    if [[ -z "${DISPLAY:-}" ]]; then
        warn "$(t nested_no_host_display)"
        VED_GUI_TARGET="host"
        return 1
    fi

    display=""
    for n in 10 11 12 13 14 15 16 17 18 19; do
        if [[ ! -e "/tmp/.X11-unix/X$n" ]]; then
            display=":$n"
            break
        fi
    done

    if [[ -z "$display" ]]; then
        warn "$(t nested_unavailable)"
        VED_GUI_TARGET="host"
        return 1
    fi

    Xephyr "$display" -screen 1280x800 -ac -noreset \
        +iglx +extension GLX +extension RENDER >/dev/null 2>&1 &
    VED_NESTED_PID=$!
    cleanup_add_pid "$VED_NESTED_PID"

    for attempt in {1..50}; do
        if [[ -e "/tmp/.X11-unix/X${display#:}" ]]; then
            VED_NESTED_DISPLAY="$display"
            info "$(t nested_started "$display")"
            info "$(t nested_software_gl)"
            return 0
        fi
        if ! kill -0 "$VED_NESTED_PID" 2>/dev/null; then
            break
        fi
        sleep 0.1
    done

    warn "$(t nested_failed)"
    VED_GUI_TARGET="host"
    VED_NESTED_PID=""
    VED_NESTED_DISPLAY=""
    return 1
}

# GNOME >= 49 no longer supports X11 sessions (not even under Xephyr).
# Launch gnome-shell --devkit: a nested Wayland window on the host display.
VED_GUEST_GNOME_MAJOR=""
VED_GUEST_DEVKIT_OK=0

detect_gnome_major() {
    local root="${1:-$VED_CHROOT_DIR}"
    local out major

    [[ -x "$root/usr/bin/gnome-shell" ]] || return 1
    out="$(timeout 10 chroot "$root" /usr/bin/gnome-shell --version 2>/dev/null)" ||
        return 1
    major="$(grep -oE '[0-9]+' <<<"$out" | head -n1)"
    [[ -n "$major" ]] || return 1
    printf '%s' "$major"
}

guest_has_devkit() {
    local root="$1" path
    for path in /usr/libexec/mutter-devkit /usr/lib/mutter-devkit \
        /usr/lib64/mutter-devkit; do
        [[ -x "$root$path" ]] && return 0
    done
    return 1
}

# Call with the root already mounted and the session already selected (before select_gui_target).
session_probe_guest() {
    local root="$1"

    VED_GUEST_GNOME_MAJOR=""
    VED_GUEST_DEVKIT_OK=0
    [[ "$VED_SESSION" == "desktop" ]] || return 0
    [[ -z "$VED_COMMAND" ]] || return 0       # the user chose their own command

    VED_GUEST_GNOME_MAJOR="$(detect_gnome_major "$root" || true)"
    [[ "${VED_GUEST_GNOME_MAJOR:-0}" -ge 49 ]] || {
        VED_GUEST_GNOME_MAJOR=""
        return 0
    }

    if [[ "$VED_GUI_TARGET" == "nested" ]]; then
        warn "$(t gnome_no_x11_nested "$VED_GUEST_GNOME_MAJOR")"
    else
        info "$(t gnome_using_devkit "$VED_GUEST_GNOME_MAJOR")"
    fi
    VED_GUI_TARGET="host"        # avoids Xephyr and the assistant's question

    if guest_has_devkit "$root"; then
        VED_GUEST_DEVKIT_OK=1
    else
        warn "$(t gnome_devkit_missing)"
    fi
}

# Replaces session_build_command in the backends. Emits no warnings; outputs only the command.
session_build_command_ex() {
    local root="$1"
    local cmd='gnome-shell --devkit --wayland --wayland-display ved-$$'

    if [[ -n "${VED_GUEST_GNOME_MAJOR:-}" ]]; then
        [[ "$VED_GUEST_DEVKIT_OK" -eq 1 ]] || return 1
        if [[ -x "$root/usr/bin/dbus-run-session" ||
            -x "$root/bin/dbus-run-session" ]]; then
            cmd="dbus-run-session -- $cmd"
        fi
        printf '%s' "$cmd"      # $$ is expanded by the guest's sh, not by ved.
        return 0
    fi

    session_build_command "$root"
}