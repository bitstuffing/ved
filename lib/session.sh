session_is_graphical() {
    [[ "$VED_SESSION" == "app" || "$VED_SESSION" == "desktop" ]]
}

# XDG_CURRENT_DESKTOP is a colon-separated list; .desktop files use
# DesktopNames with semicolons. Never fall back to the host's values here:
# that makes guest applications see the host desktop (and breaks apps such as
# MSEdge which select integrations from these variables).
set_guest_desktop_identity() {
    local names="$1"
    local part
    local -a parts=()
    local -a cleaned=()

    [[ -n "$names" ]] || return 1

    IFS=':;' read -r -a parts <<< "$names"
    for part in "${parts[@]}"; do
        part="${part//[[:space:]]/}"
        [[ -n "$part" ]] && cleaned+=("$part")
    done
    ((${#cleaned[@]} > 0)) || return 1

    printf -v VED_GUEST_CURRENT_DESKTOP '%s:' "${cleaned[@]}"
    VED_GUEST_CURRENT_DESKTOP="${VED_GUEST_CURRENT_DESKTOP%:}"
    VED_GUEST_SESSION_DESKTOP="${cleaned[0],,}"

    return 0
}

guest_desktop_identity_for_file() {
    local root="$1"
    local id="$2"
    local file names name base

    [[ -n "$id" ]] || return 1
    file="$root/usr/share/$id"
    [[ -r "$file" ]] || return 1

    names="$(sed -n 's/^DesktopNames=//p' "$file" | head -n1 || true)"
    names="${names//|/}"
    names="${names//$'\r'/}"
    names="$(printf '%s' "$names" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    if set_guest_desktop_identity "$names"; then
        return 0
    fi

    # Older/fallback .desktop files may omit DesktopNames. Use a readable
    # name first ("GNOME on Xorg" -> GNOME), then the file basename.
    name="$(sed -n 's/^Name=//p' "$file" | head -n1 || true)"
    name="${name%% on *}"
    name="${name%% *}"
    base="${id##*/}"
    base="${base%.desktop}"
    set_guest_desktop_identity "${name:-$base}"
}

guest_desktop_identity_for_command() {
    local command="${1,,}"

    case "$command" in
        *gnome-session*|*gnome-shell*) set_guest_desktop_identity 'GNOME' ;;
        *startplasma*|*plasma*) set_guest_desktop_identity 'KDE' ;;
        *startxfce4*) set_guest_desktop_identity 'XFCE' ;;
        *cinnamon-session*) set_guest_desktop_identity 'X-Cinnamon' ;;
        *mate-session*) set_guest_desktop_identity 'MATE' ;;
        *lxqt-session*) set_guest_desktop_identity 'LXQt' ;;
        *lxsession*) set_guest_desktop_identity 'LXDE' ;;
        *) return 1 ;;
    esac
}

ensure_guest_desktop_identity() {
    local command="$1"

    [[ "$VED_SESSION" == "desktop" ]] || return 0
    [[ -z "$VED_GUEST_CURRENT_DESKTOP" ]] || return 0
    [[ -n "$command" ]] || return 0

    guest_desktop_identity_for_command "$command" || true
}

select_session_menu() {
    local option

    echo
    info "$(t select_session)"
    printf '  1) %s\n' "$(t session_shell)"
    printf '  2) %s\n' "$(t session_app)"
    printf '  3) %s\n' "$(t session_desktop)"
    if [[ "$VED_BACKEND" != "docker" ]]; then
        printf '  4) %s\n' "$(t session_system)"
    fi
    echo

    option="$(ask "$(t select_session_prompt)" "1")"
    case "$option" in
        1) VED_SESSION="shell" ;;
        2) VED_SESSION="app" ;;
        3) VED_SESSION="desktop" ;;
        4)
            if [[ "$VED_BACKEND" == "docker" ]]; then
                die "$(t docker_system_unsupported)"
            fi
            VED_SESSION="system"
            ;;
        *) die "$(t invalid_option)" ;;
    esac
    VED_SESSION_SET=1
}

select_session() {
    if [[ "$VED_SESSION_SET" -eq 1 || "$VED_SESSION" != "auto" ]]; then
        return
    fi

    if [[ "$VED_GRAPHICAL" -eq 1 || ! -t 0 ]]; then
        VED_SESSION="shell"
        return
    fi

    select_session_menu
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
    local wayland_name
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
    VED_WAYLAND_EXPORT_FAILED=0
    VED_GUEST_WAYLAND_DISPLAY=""
    if [[ "$VED_GUI_TARGET" != "nested" && -n "${WAYLAND_DISPLAY:-}" ]]; then
        wayland_source="$VED_GUI_RUNTIME/$WAYLAND_DISPLAY"
        if [[ "$WAYLAND_DISPLAY" == /* ]]; then
            wayland_source="$WAYLAND_DISPLAY"
        fi
        wayland_name="${wayland_source##*/}"
        if guest_starts_compositor; then
            # A nested compositor needs the host Wayland socket as a client,
            # but also creates its own wayland-0 server socket. Exporting the
            # host socket under the same name makes that bind fail with
            # "Device or resource busy"; use a distinct name for the client.
            wayland_name="ved-host-$wayland_name"
        fi
        if [[ -e "$wayland_source" || -S "$wayland_source" ]] &&
            gui_runtime_export_socket "$wayland_source" \
                "$runtime/$wayland_name"; then
            VED_GUEST_WAYLAND_DISPLAY="$wayland_name"
        else
            # Do not pass the host's socket *name* to the guest when the
            # socket itself could not be exported: it does not exist in the
            # private runtime dir and compositors report a broken Wayland
            # socket. Fall back to X11 (except for the self-contained devkit
            # path, which creates its own display).
            VED_WAYLAND_EXPORT_FAILED=1
            VED_GUEST_WAYLAND_DISPLAY=""
            warn "$(t wayland_socket_unavailable)"
            if [[ "$VED_GUI_SESSION_TYPE" == "wayland" ]]; then
                VED_GUI_SESSION_TYPE="x11"
            fi
            if [[ "$VED_COMMAND" != *--devkit* &&
                  "$VED_GUEST_SESSION_TYPE" == "wayland" ]]; then
                VED_GUEST_SESSION_TYPE="x11"
            fi
        fi
    fi
}

detect_desktop_sessions() {
    local root="$1"
    local directory
    local directory_type
    local file
    local name
    local exec
    local try_exec
    local id
    local -A seen=()

    for directory in \
        "$root/usr/share/wayland-sessions" \
        "$root/usr/share/xsessions"; do

        if [[ "$directory" == */wayland-sessions ]]; then
            directory_type="wayland"
        else
            directory_type="x11"
        fi

        [[ -d "$directory" ]] || continue

        for file in "$directory"/*.desktop; do
            [[ -f "$file" ]] || continue

            name="$(sed -n 's/^Name=//p' "$file" | head -n1)"
            exec="$(sed -n 's/^Exec=//p' "$file" | head -n1)"
            try_exec="$(sed -n 's/^TryExec=//p' "$file" | head -n1)"

            [[ -n "$name" && -n "$exec" ]] || continue

            grep -qiE '^(Hidden|NoDisplay)=true$' "$file" && continue

            if [[ -n "$try_exec" ]]; then
                if [[ ! -x "$root$try_exec" &&
                      ! -x "$root/usr/bin/$try_exec" &&
                      ! -x "$root/usr/sbin/$try_exec" ]]; then
                    continue
                fi
            fi

            # Field codes make no sense when a session is launched directly.
            exec="$(printf '%s' "$exec" |
                sed -E 's/[[:space:]]+%[a-zA-Z]+//g; s/[[:space:]]+$//')"
            [[ -n "$exec" ]] || continue

            id="${directory##*/}/$(basename "$file")"

            [[ -n "${seen[$id]:-}" ]] && continue
            seen["$id"]=1

            printf '%s|%s|%s|%s\n' \
                "$name" "$exec" "$id" "$directory_type"
        done
    done
}

# Only offer sessions that can actually work with the requested display
# target. Xephyr is X11 only, a Wayland session needs a compositor socket and
# GNOME >= 49 has no working X11 session at all.
desktop_session_supported() {
    local entry="$1"
    local name exec id type

    IFS='|' read -r name exec id type <<< "$entry"

    case "$type" in
        wayland|x11) ;;
        *) return 1 ;;
    esac

    if [[ "$VED_GUI_TARGET" == "nested" && "$type" != "x11" ]]; then
        return 1
    fi

    if [[ "$type" == "x11" && "${VED_GUEST_NO_X11:-0}" -eq 1 ]]; then
        case "${name,,} ${exec,,} ${id,,}" in
            *gnome*) return 1 ;;
        esac
    fi

    if [[ "$type" == "wayland" && "$VED_GUI_TARGET" != "nested" &&
          -z "${WAYLAND_DISPLAY:-}" &&
          -z "${VED_GUEST_WAYLAND_DISPLAY:-}" ]]; then
        return 1
    fi

    return 0
}

select_desktop_session() {
    local root="$1"
    local -a sessions=()
    local -a supported=()
    local entry
    local option
    local i
    local name exec id type

    [[ "$VED_SESSION" == "desktop" ]] || return 0
    [[ -z "$VED_COMMAND" ]] || return 0

    mapfile -t sessions < <(detect_desktop_sessions "$root")

    for entry in "${sessions[@]}"; do
        desktop_session_supported "$entry" && supported+=("$entry")
    done

    if ((${#supported[@]} == 0)); then
        if ((${#sessions[@]} > 0)); then
            warn "$(t desktop_session_incompatible)"
        fi
        return 1
    fi

    if ((${#supported[@]} == 1)); then
        entry="${supported[0]}"
    elif [[ ! -t 0 ]]; then
        return 1
    else
        echo
        info "$(t desktop_sessions_available)"
        echo

        for i in "${!supported[@]}"; do
            entry="${supported[$i]}"
            printf '  %d) %s\n' "$((i + 1))" "${entry%%|*}"
        done

        echo
        option="$(ask "$(t desktop_session_prompt)" "1")"

        [[ "$option" =~ ^[0-9]+$ ]] || return 1
        (( option >= 1 && option <= ${#supported[@]} )) || return 1

        entry="${supported[$((option - 1))]}"
    fi

    IFS='|' read -r name exec id type <<< "$entry"
    VED_COMMAND="$exec"
    VED_GUEST_SESSION_TYPE="$type"
    guest_desktop_identity_for_file "$root" "$id" || true

    return 0
}

session_build_command() {
    local root="$1"
    local command="$VED_COMMAND"
    local user_manager=""

    case "$VED_SESSION" in
        desktop)
            if [[ -z "$command" ]]; then
                select_desktop_session "$root" || return 1
                command="$VED_COMMAND"
            fi

            [[ -n "$command" ]] || return 1

            # Do not wrap a command that already owns its session bus.
            case "$command" in
                dbus-run-session[[:space:]]--*|systemd-run[[:space:]]*)
                    printf '%s' "$command"
                    return 0
                    ;;
            esac

            # systemd-run --user only when a systemd *user* manager is
            # running inside the container.
            if [[ -n "${VED_GUEST_RUNTIME:-}" ]]; then
                user_manager="$root$VED_GUEST_RUNTIME/systemd/private"
            fi

            if [[ "$VED_BACKEND" == "nspawn" &&
                  "$command" != *--devkit* &&
                  -S "$user_manager" &&
                  ( -x "$root/usr/bin/systemd-run" ||
                    -x "$root/bin/systemd-run" ) ]]; then

                command="systemd-run --user --scope -- $command"

            elif [[ "$command" != *plasma-dbus-run-session-if-needed* &&
                   ( -x "$root/usr/bin/dbus-run-session" ||
                     -x "$root/bin/dbus-run-session" ) ]]; then

                command="dbus-run-session -- $command"
            fi
            ;;
    esac

    printf '%s' "$command"
}

session_build_command_ex() {
    local root="$1"
    session_build_command "$root"
}

# True when the guest itself is a Wayland compositor (Xfce Wayland, labwc,
# GNOME devkit, ...). In that case host Wayland/X11 sockets must not be exported
# into the guest runtime: the guest creates its own and they collide.
guest_starts_compositor() {
    [[ "$VED_SESSION" == "desktop" ]] || return 1
    [[ "${VED_GUEST_SESSION_TYPE:-}" == "wayland" ||
       "$VED_COMMAND" == *--devkit* ]]
}

guest_display_value() {
    local display_number=90

    if [[ "$VED_GUI_TARGET" == "nested" && -n "$VED_NESTED_DISPLAY" ]]; then
        printf '%s' "$VED_NESTED_DISPLAY"
        return 0
    fi

    # A Wayland compositor inside the guest starts its own Xwayland. It cannot
    # use the host's X display number because /tmp/.X11-unix is shared with the
    # host and X0 is already taken. GNOME's devkit path owns its display, so it
    # keeps the normal value.
    if [[ "${VED_GUEST_SESSION_TYPE:-}" == "wayland" &&
          "$VED_COMMAND" != *--devkit* ]]; then
        while [[ -e "/tmp/.X11-unix/X$display_number" ]]; do
            ((display_number += 1))
        done
        printf ':%s' "$display_number"
        return 0
    fi

    printf '%s' "${DISPLAY:-:0}"
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

    # Prefer package metadata. Executing a guest binary with chroot() at this
    # point is fragile (/dev, /proc and /sys are not bound yet), and a silent
    # failure here would let a GNOME 49+ guest fall back to its broken X11
    # session.
    if have rpm; then
        out="$(rpm --root "$root" -q --qf '%{VERSION}\n' gnome-shell 2>/dev/null |
            head -n1 || true)"
        out="${out#*:}"   # drop an epoch such as "1:49.0"
        major="$(grep -oE '[0-9]+' <<< "$out" | head -n1 || true)"
        [[ -n "$major" ]] && {
            printf '%s' "$major"
            return 0
        }
    fi

    if have dpkg-query; then
        out="$(dpkg-query --root="$root" -W -f='${Version}\n' gnome-shell 2>/dev/null |
            head -n1 || true)"
        out="${out#*:}"
        major="$(grep -oE '[0-9]+' <<< "$out" | head -n1 || true)"
        [[ -n "$major" ]] && {
            printf '%s' "$major"
            return 0
        }
    fi

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

# Call with the root already mounted and before the session/GUI is selected.
# GNOME >= 49 has no X11 session, so leftover gnome-xorg.desktop entries must
# never be offered. With mutter-devkit we can still start a nested Wayland
# shell on the host display.
session_probe_guest() {
    local root="$1"

    VED_GUEST_GNOME_MAJOR=""
    VED_GUEST_DEVKIT_OK=0
    VED_GUEST_NO_X11=0
    VED_GUEST_SESSION_DESKTOP=""
    VED_GUEST_CURRENT_DESKTOP=""

    [[ "$VED_SESSION" == "desktop" ]] || return 0
    [[ -z "$VED_COMMAND" ]] || return 0

    VED_GUEST_GNOME_MAJOR="$(detect_gnome_major "$root" || true)"

    [[ "${VED_GUEST_GNOME_MAJOR:-0}" -ge 49 ]] || {
        VED_GUEST_GNOME_MAJOR=""
        return 0
    }

    VED_GUEST_NO_X11=1

    if [[ "$VED_GUI_TARGET" == "nested" ]]; then
        warn "$(t gnome_no_x11_nested "$VED_GUEST_GNOME_MAJOR")"
    fi
    VED_GUI_TARGET="host"

    if guest_has_devkit "$root"; then
        VED_GUEST_DEVKIT_OK=1
        VED_COMMAND='gnome-shell --devkit --wayland --wayland-display ved-$$'
        VED_GUEST_SESSION_TYPE="wayland"
        set_guest_desktop_identity 'GNOME' || true
        info "$(t gnome_using_devkit "$VED_GUEST_GNOME_MAJOR")"
    else
        warn "$(t gnome_devkit_missing "$VED_GUEST_GNOME_MAJOR")"
    fi

    return 0
}
