require_tty() {
    if [[ ! -t 0 ]]; then
        die "$(t no_tty)"
    fi
}

ask() {
    local prompt="$1"
    local default="$2"
    local answer=""

    require_tty
    read -r -p "$prompt" answer || answer=""
    printf '%s' "${answer:-$default}"
}

confirm_key() {
    local key="$1"
    local default_yes="${2:-0}"
    local default answer

    if [[ "$VED_ASSUME_YES" -eq 1 ]]; then
        return 0
    fi

    if [[ "$default_yes" -eq 1 ]]; then
        default="y"
    else
        default="n"
    fi

    answer="$(ask "$(t "$key")" "$default")"
    case "${answer,,}" in
        y|yes|s|si|sí) return 0 ;;
        *) return 1 ;;
    esac
}

select_backend() {
    local option

    if [[ "$VED_BACKEND_SET" -eq 1 ]]; then
        return
    fi

    if [[ ! -t 0 ]]; then
        VED_BACKEND="qemu"
        return
    fi

    echo
    info "$(t select_action)"
    printf '  1) %s\n' "$(t backend_qemu)"
    printf '  2) %s\n' "$(t backend_chroot)"
    printf '  3) %s\n' "$(t backend_nspawn)"
    echo

    option="$(ask "$(t select_backend_prompt)" "1")"
    case "$option" in
        1) VED_BACKEND="qemu" ;;
        2) VED_BACKEND="chroot" ;;
        3) VED_BACKEND="nspawn" ;;
        *) die "$(t invalid_option)" ;;
    esac
    VED_BACKEND_SET=1
}

accel_text() {
    case "${VED_ACCEL_ACTUAL:-}" in
        kvm) t value_kvm ;;
        tcg) t value_tcg ;;
        '') printf '%s' "$(t auto_value)" ;;
        *) printf '%s' "$VED_ACCEL_ACTUAL" ;;
    esac
}

cpu_total() {
    local total
    total="$(nproc --all 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')"
    printf '%s' "$total"
}

cpu_available() {
    local available
    available="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')"
    printf '%s' "$available"
}

select_memory() {
    local total_mib available_mib recommended_mib recommended_gib
    local answer

    if [[ -n "$VED_RAM" ]]; then
        if [[ "$VED_RAM" =~ ^[0-9]+$ ]]; then
            VED_RAM="${VED_RAM}M"
        elif [[ "$VED_RAM" =~ ^[1-9][0-9]*[MGmg]$ ]]; then
            VED_RAM="${VED_RAM^^}"
        else
            die "$(t invalid_memory)"
        fi
        return
    fi

    total_mib="$(awk '/MemTotal:/ {printf "%d\n", $2 / 1024}' /proc/meminfo)"
    available_mib="$(awk '/MemAvailable:/ {printf "%d\n", $2 / 1024}' /proc/meminfo)"

    recommended_mib=$((total_mib / 2))
    if ((recommended_mib > 16384)); then
        recommended_mib=16384
    fi
    if ((recommended_mib < 2048)); then
        recommended_mib=2048
    fi
    recommended_gib=$((recommended_mib / 1024))
    if ((recommended_gib < 1)); then
        recommended_gib=1
    fi

    if [[ ! -t 0 ]]; then
        VED_RAM="${recommended_gib}G"
        return
    fi

    echo
    info "$(t system_memory)"
    info "$(t total_memory "$total_mib")"
    info "$(t available_memory "$available_mib")"
    info "$(t recommended_memory "$recommended_gib")"
    echo

    while true; do
        answer="$(ask "$(t select_memory "$recommended_gib")" "${recommended_gib}G")"
        if [[ "$answer" =~ ^[0-9]+[MGmg]$ ]]; then
            VED_RAM="${answer^^}"
            return
        fi
        warn "$(t invalid_memory)"
    done
}

select_cpus() {
    local total available recommended answer
    local recommended_display

    if [[ -n "$VED_CPUS" ]]; then
        if [[ ! "$VED_CPUS" =~ ^[0-9]+$ ]] || ((VED_CPUS < 1)); then
            die "$(t invalid_cpus "$(cpu_total)")"
        fi
        return
    fi

    total="$(cpu_total)"
    available="$(cpu_available)"
    recommended=$((available / 2))
    if ((recommended < 1)); then
        recommended=1
    fi
    if ((recommended > total)); then
        recommended="$total"
    fi
    recommended_display="$recommended"

    if [[ ! -t 0 ]]; then
        VED_CPUS="$recommended"
        return
    fi

    echo
    info "$(t processors)"
    info "$(t total_processors "$total")"
    info "$(t available_processors "$available")"
    info "$(t recommended_processors "$recommended_display")"
    echo

    while true; do
        answer="$(ask "$(t select_cpus "$recommended_display")" "$recommended_display")"
        if [[ "$answer" =~ ^[0-9]+$ ]] &&
            ((answer >= 1 && answer <= total)); then
            VED_CPUS="$answer"
            return
        fi
        warn "$(t invalid_cpus "$total")"
    done
}

select_storage_mode() {
    local option

    if [[ -n "$VED_STORAGE_MODE" ]]; then
        case "$VED_STORAGE_MODE" in
            temp) VED_STORAGE_OPTS=(-snapshot) ;;
            persistent) VED_STORAGE_OPTS=() ;;
        esac
        return
    fi

    if [[ ! -t 0 ]]; then
        VED_STORAGE_MODE="temp"
        VED_STORAGE_OPTS=(-snapshot)
        return
    fi

    echo
    info "$(t storage_mode)"
    printf '  1) %s\n' "$(t temporary_storage)"
    printf '  2) %s\n' "$(t persistent_storage)"
    echo

    option="$(ask "$(t select_storage)" "1")"

    case "$option" in
        1)
            VED_STORAGE_MODE="temp"
            VED_STORAGE_OPTS=(-snapshot)
            info "$(t temporary_selected)"
            ;;
        2)
            VED_STORAGE_MODE="persistent"
            VED_STORAGE_OPTS=()
            info "$(t persistent_selected)"
            warn "$(t persistent_warning)"
            confirm_key confirm_persistent 0 || {
                info "$(t aborted)"
                exit 0
            }
            ;;
        *)
            die "$(t invalid_option)"
            ;;
    esac
}

select_display_mode() {
    if [[ "$VED_DISPLAY_MODE" != "auto" ]]; then
        return
    fi
}

show_configuration() {
    echo
    info "$(t configuration)"
    msg backend_label "$VED_BACKEND"
    if [[ -n "$VED_IMAGE" ]]; then
        msg image_label "$VED_IMAGE"
    fi
    if [[ -n "$VED_DISK" ]]; then
        msg disk_label "$VED_DISK"
    fi
    if [[ -n "$VED_ROOT_PARTITION" ]]; then
        msg partition_label "$VED_ROOT_PARTITION"
    fi
    if [[ -n "$VED_ESP" ]]; then
        msg efi_label "$VED_ESP"
    fi
    if [[ -n "$VED_RAM" ]]; then
        msg ram_label "$VED_RAM"
    fi
    if [[ -n "$VED_CPUS" ]]; then
        msg cpu_label "$VED_CPUS"
    fi
    if [[ -n "$VED_STORAGE_MODE" ]]; then
        msg storage_label "$VED_STORAGE_MODE"
    fi
    if [[ "$VED_BACKEND" == "qemu" ]]; then
        local planned="${VED_DISPLAY_PLANNED_MODE:-$VED_DISPLAY_MODE}"
        msg accel_label "$(accel_text)"
        msg display_label "$planned"
        if [[ "$planned" == *-gl ]]; then
            msg gl_label "$(t value_enabled)"
            if [[ -n "${VED_DISPLAY_PLANNED_NODE:-}" ]]; then
                msg render_label "$VED_DISPLAY_PLANNED_NODE"
            fi
        else
            msg gl_label "$(t value_disabled)"
        fi
        msg guest_label "$VED_GUEST_OS"
        msg arch_label "$VED_ARCH"
        msg network_label "$VED_NETWORK"
        if ((${#VED_USB_SUMMARY[@]} > 0)); then
            local usb_list
            usb_list="$(printf '%s, ' "${VED_USB_SUMMARY[@]}")"
            msg usb_label "${usb_list%, }"
        fi
        if [[ "$VED_SECURE_BOOT" -eq 1 ]]; then
            msg secure_boot_label "$(t yes_value)"
        fi
    fi
    if [[ "$VED_BACKEND" != "qemu" && "$VED_SESSION" != "auto" ]]; then
        msg session_label "$(t "session_${VED_SESSION}")"
        if session_is_graphical && [[ "$VED_GUI_TARGET" != "auto" ]]; then
            msg gui_label "$(t "gui_target_${VED_GUI_TARGET}")"
        fi
    fi
    if [[ "$VED_GRAPHICAL" -eq 1 ]]; then
        msg graphical_label "$(t yes_value)"
    fi
    msg tmp_label "$VED_VM_DIR"
    echo
}
