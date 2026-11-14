VED_DISPLAY_ARGS=()
VED_DISPLAY_NEEDS_VIEWER=0
VED_VNC_PORT=5900
VED_DISPLAY_PLANNED_MODE=""
VED_DISPLAY_PLANNED_NODE=""

display_build_args() {
    local mode="$1"
    local render_node="${2:-}"
    local spice_opts="unix=on,addr=$VED_SPICE_SOCKET,disable-ticketing=on"

    VED_DISPLAY_ARGS=()
    VED_DISPLAY_NEEDS_VIEWER=0

    case "$mode" in
        spice-gl)
            if [[ -n "$render_node" ]]; then
                spice_opts="$spice_opts,gl=on,rendernode=$render_node"
            else
                spice_opts="$spice_opts,gl=on"
            fi
            VED_DISPLAY_ARGS=(
                -display none
                -device virtio-vga-gl
                -spice "$spice_opts"
            )
            VED_DISPLAY_NEEDS_VIEWER=1
            ;;
        spice)
            VED_DISPLAY_ARGS=(
                -display none
                -device virtio-vga
                -spice "$spice_opts"
            )
            VED_DISPLAY_NEEDS_VIEWER=1
            ;;
        gtk-gl)
            VED_DISPLAY_ARGS=(
                -display "gtk,gl=on"
                -device virtio-vga-gl
            )
            ;;
        gtk)
            VED_DISPLAY_ARGS=(
                -display gtk
                -device virtio-vga
            )
            ;;
        sdl)
            VED_DISPLAY_ARGS=(
                -display sdl
                -device virtio-vga
            )
            ;;
        vnc)
            VED_DISPLAY_ARGS=(
                -display none
                -device virtio-vga
                -vnc "127.0.0.1:0"
            )
            VED_DISPLAY_NEEDS_VIEWER=2
            ;;
        none)
            VED_DISPLAY_ARGS=(
                -display none
                -device virtio-vga
            )
            ;;
        *)
            return 1
            ;;
    esac
}

display_is_spice() {
    case "$1" in
        spice|spice-gl) return 0 ;;
        *) return 1 ;;
    esac
}

spice_agent_args() {
    if display_is_spice "$1"; then
        printf '%s\0' \
            -device virtio-serial-pci \
            -chardev spicevmc,id=vdagent,name=vdagent \
            -device virtserialport,chardev=vdagent,name=com.redhat.spice.0
    fi
}

spice_find_viewer() {
    if have remote-viewer; then
        printf '%s' "remote-viewer"
    elif have virt-viewer; then
        printf '%s' "virt-viewer"
    elif have spicy; then
        printf '%s' "spicy"
    else
        printf '%s' ""
    fi
}

display_viewer_available() {
    case "$1" in
        spice|spice-gl)
            [[ -n "$(spice_find_viewer)" ]]
            ;;
        vnc)
            have remote-viewer || have virt-viewer || have vncviewer
            ;;
        *)
            return 0
            ;;
    esac
}

display_launch_viewer() {
    local mode="$1"
    local viewer
    local uri

    if [[ "$VED_DISPLAY_NEEDS_VIEWER" -eq 0 ]]; then
        return 0
    fi

    if [[ "$VED_DISPLAY_NEEDS_VIEWER" -eq 2 ]]; then
        if have remote-viewer; then
            viewer="remote-viewer"
        elif have virt-viewer; then
            viewer="virt-viewer"
        elif have vncviewer; then
            viewer="vncviewer"
        else
            viewer=""
        fi
        uri="vnc://127.0.0.1:$VED_VNC_PORT"
    else
        viewer="$(spice_find_viewer)"
        uri="spice+unix://$VED_SPICE_SOCKET"
    fi

    if [[ ! -S "$VED_SPICE_SOCKET" && "$VED_DISPLAY_NEEDS_VIEWER" -eq 1 ]]; then
        return 1
    fi

    if [[ "$VED_DISPLAY_NEEDS_VIEWER" -eq 1 ]] && [[ -n "$VED_GUI_USER" ]]; then
        chown "$VED_GUI_UID:$VED_GUI_GID" "$VED_SPICE_SOCKET" 2>/dev/null || true
        chmod 660 "$VED_SPICE_SOCKET" 2>/dev/null || true
    fi

    if [[ -z "$viewer" ]] || ! have "$viewer"; then
        info "$(t no_viewer "$uri")"
        if [[ -n "$VED_QEMU_PID" ]] && kill -0 "$VED_QEMU_PID" 2>/dev/null; then
            wait "$VED_QEMU_PID" 2>/dev/null || true
        fi
        return 0
    fi

    echo
    info "$(t connecting_viewer)"
    if [[ -n "$VED_GUI_USER" ]]; then
        info "$(t graphical_user "$VED_GUI_USER")"
    fi
    info "$(t resize_hint)"
    echo

    local -a viewer_command=("$viewer")
    if [[ "$viewer" == "spicy" ]]; then
        viewer_command+=(--uri "$uri")
    else
        viewer_command+=("$uri")
    fi

    if [[ -n "$VED_GUI_USER" ]]; then
        run_as_gui_user "${viewer_command[@]}" || true
    else
        "${viewer_command[@]}" || true
    fi

    return 0
}
