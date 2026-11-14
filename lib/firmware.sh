ovmf_available() {
    local candidate
    local -a candidates=(
        /usr/share/edk2/ovmf/OVMF_CODE_4M.fd
        /usr/share/edk2/ovmf/OVMF_CODE.fd
        /usr/share/OVMF/OVMF_CODE_4M.fd
        /usr/share/OVMF/OVMF_CODE.fd
        /usr/share/edk2/x64/OVMF_CODE.4m.fd
        /usr/share/edk2/x64/OVMF_CODE.fd
        /usr/share/qemu/ovmf-x86_64-code.bin
        /usr/share/edk2/ovmf/OVMF_CODE_4M.qcow2
    )

    for candidate in "${candidates[@]}"; do
        [[ -f "$candidate" ]] && return 0
    done

    find /usr/share/edk2 /usr/share/OVMF /usr/share/qemu /usr/share/edk2-ovmf \
        -maxdepth 2 -type f -name 'OVMF_CODE*' -print 2>/dev/null |
        head -n1 | grep -q .
}

ovmf_format_for() {
    case "$1" in
        *.qcow2) printf '%s' "qcow2" ;;
        *) printf '%s' "raw" ;;
    esac
}

aavmf_available() {
    local candidate
    local -a candidates=(
        /usr/share/AAVMF/AAVMF_CODE.fd
        /usr/share/AAVMF/AAVMF_CODE.secboot.fd
        /usr/share/edk2/aarch64/QEMU_EFI.fd
        /usr/share/edk2/aarch64/QEMU_EFI-pflash.raw
        /usr/share/edk2/aarch64/QEMU_CODE.fd
        /usr/share/qemu-efi-aarch64/QEMU_EFI.fd
    )

    for candidate in "${candidates[@]}"; do
        [[ -f "$candidate" ]] && return 0
    done

    find /usr/share/AAVMF /usr/share/edk2/aarch64 /usr/share/qemu-efi-aarch64 \
        -maxdepth 2 -type f \( -name 'AAVMF_CODE*' -o -name 'QEMU_EFI*' -o -name 'QEMU_CODE*' \) \
        -print 2>/dev/null | head -n1 | grep -q .
}

detect_aavmf_files() {
    local -a code_candidates=() vars_candidates=()
    local file found_code="" found_vars=""

    if [[ "$VED_SECURE_BOOT" -eq 1 ]]; then
        code_candidates=(
            /usr/share/AAVMF/AAVMF_CODE.secboot.fd
            /usr/share/edk2/aarch64/QEMU_EFI.secboot.fd
            /usr/share/AAVMF/AAVMF_CODE.fd
            /usr/share/edk2/aarch64/QEMU_EFI.fd
            /usr/share/edk2/aarch64/QEMU_EFI-pflash.raw
            /usr/share/qemu-efi-aarch64/QEMU_EFI.fd
            /usr/share/edk2/aarch64/QEMU_CODE.fd
        )
        vars_candidates=(
            /usr/share/AAVMF/AAVMF_VARS.secboot.fd
            /usr/share/AAVMF/AAVMF_VARS.fd
            /usr/share/edk2/aarch64/QEMU_VARS.fd
            /usr/share/qemu-efi-aarch64/QEMU_VARS.fd
        )
    else
        code_candidates=(
            /usr/share/AAVMF/AAVMF_CODE.fd
            /usr/share/edk2/aarch64/QEMU_EFI.fd
            /usr/share/edk2/aarch64/QEMU_EFI-pflash.raw
            /usr/share/qemu-efi-aarch64/QEMU_EFI.fd
            /usr/share/edk2/aarch64/QEMU_CODE.fd
            /usr/share/AAVMF/AAVMF_CODE.secboot.fd
        )
        vars_candidates=(
            /usr/share/AAVMF/AAVMF_VARS.fd
            /usr/share/edk2/aarch64/QEMU_VARS.fd
            /usr/share/qemu-efi-aarch64/QEMU_VARS.fd
            /usr/share/AAVMF/AAVMF_VARS.secboot.fd
        )
    fi

    for file in "${code_candidates[@]}"; do
        if [[ -f "$file" ]]; then
            found_code="$file"
            break
        fi
    done

    for file in "${vars_candidates[@]}"; do
        if [[ -f "$file" ]]; then
            found_vars="$file"
            break
        fi
    done

    if [[ -z "$found_code" ]]; then
        found_code="$(find /usr/share/AAVMF /usr/share/edk2/aarch64 /usr/share/qemu-efi-aarch64 \
            -maxdepth 2 -type f \( -name 'AAVMF_CODE*' -o -name 'QEMU_EFI*' -o -name 'QEMU_CODE*' \) \
            2>/dev/null | sort | head -n1 || true)"
    fi

    if [[ -z "$found_vars" ]]; then
        found_vars="$(find /usr/share/AAVMF /usr/share/edk2/aarch64 /usr/share/qemu-efi-aarch64 \
            -maxdepth 2 -type f \( -name 'AAVMF_VARS*' -o -name 'QEMU_VARS*' \) \
            2>/dev/null | sort | head -n1 || true)"
    fi

    [[ -n "$found_code" ]] || die "$(t aavmf_missing)"
    [[ -n "$found_vars" ]] || die "$(t aavmf_missing)"

    VED_OVMF_CODE="$found_code"
    VED_OVMF_VARS_TEMPLATE="$found_vars"
    VED_OVMF_CODE_FORMAT="$(ovmf_format_for "$VED_OVMF_CODE")"
    VED_OVMF_VARS_FORMAT="$(ovmf_format_for "$VED_OVMF_VARS_TEMPLATE")"

    debug "AAVMF code: $VED_OVMF_CODE ($VED_OVMF_CODE_FORMAT)"
    debug "AAVMF vars: $VED_OVMF_VARS_TEMPLATE ($VED_OVMF_VARS_FORMAT)"
}

detect_ovmf_files() {
    if [[ "$VED_ARCH" == "aarch64" ]]; then
        detect_aavmf_files
        return
    fi

    local -a code_candidates=() vars_candidates=()
    local file found_code="" found_vars=""

    if [[ "$VED_SECURE_BOOT" -eq 1 ]]; then
        code_candidates=(
            /usr/share/edk2/ovmf/OVMF_CODE_4M.secboot.qcow2
            /usr/share/edk2/ovmf/OVMF_CODE.secboot.fd
            /usr/share/edk2/ovmf/OVMF_CODE_4M.secboot.fd
            /usr/share/OVMF/OVMF_CODE_4M.secboot.fd
            /usr/share/OVMF/OVMF_CODE.secboot.fd
            /usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd
            /usr/share/edk2/x64/OVMF_CODE.secboot.fd
            /usr/share/qemu/ovmf-x86_64-secure-code.bin
        )
        vars_candidates=(
            /usr/share/edk2/ovmf/OVMF_VARS_4M.secboot.qcow2
            /usr/share/edk2/ovmf/OVMF_VARS.secboot.fd
            /usr/share/edk2/ovmf/OVMF_VARS_4M.secboot.fd
            /usr/share/OVMF/OVMF_VARS_4M.secboot.fd
            /usr/share/OVMF/OVMF_VARS.secboot.fd
            /usr/share/edk2/x64/OVMF_VARS.secboot.4m.fd
            /usr/share/edk2/x64/OVMF_VARS.secboot.fd
            /usr/share/qemu/ovmf-x86_64-secure-vars.bin
        )
    else
        code_candidates=(
            /usr/share/edk2/ovmf/OVMF_CODE_4M.fd
            /usr/share/edk2/ovmf/OVMF_CODE.fd
            /usr/share/edk2/ovmf/OVMF_CODE.cc.fd
            /usr/share/OVMF/OVMF_CODE_4M.fd
            /usr/share/OVMF/OVMF_CODE.fd
            /usr/share/edk2/x64/OVMF_CODE.4m.fd
            /usr/share/edk2/x64/OVMF_CODE.fd
            /usr/share/qemu/ovmf-x86_64-code.bin
            /usr/share/qemu/ovmf-x86_64.bin
            /usr/share/edk2-ovmf/OVMF_CODE.fd
            /usr/share/edk2/ovmf/OVMF_CODE_4M.qcow2
            /usr/share/OVMF/OVMF_CODE_4M.qcow2
        )
        vars_candidates=(
            /usr/share/edk2/ovmf/OVMF_VARS_4M.fd
            /usr/share/edk2/ovmf/OVMF_VARS.fd
            /usr/share/OVMF/OVMF_VARS_4M.fd
            /usr/share/OVMF/OVMF_VARS.fd
            /usr/share/edk2/x64/OVMF_VARS.4m.fd
            /usr/share/edk2/x64/OVMF_VARS.fd
            /usr/share/qemu/ovmf-x86_64-vars.bin
            /usr/share/edk2-ovmf/OVMF_VARS.fd
            /usr/share/edk2/ovmf/OVMF_VARS_4M.qcow2
            /usr/share/OVMF/OVMF_VARS_4M.qcow2
        )
    fi

    for file in "${code_candidates[@]}"; do
        if [[ -f "$file" ]]; then
            found_code="$file"
            break
        fi
    done

    for file in "${vars_candidates[@]}"; do
        if [[ -f "$file" ]]; then
            found_vars="$file"
            break
        fi
    done

    if [[ -z "$found_code" ]]; then
        if [[ "$VED_SECURE_BOOT" -eq 1 ]]; then
            found_code="$(find /usr/share/edk2 /usr/share/OVMF /usr/share/qemu /usr/share/edk2-ovmf \
                -maxdepth 2 -type f -name 'OVMF_CODE*secboot*' \
                ! -name '*.json' ! -name '*.pcrlock' 2>/dev/null | sort | head -n1 || true)"
        else
            found_code="$(find /usr/share/edk2 /usr/share/OVMF /usr/share/qemu /usr/share/edk2-ovmf \
                -maxdepth 2 -type f -name 'OVMF_CODE*' \
                ! -name '*secboot*' ! -name '*.json' ! -name '*.pcrlock' ! -name '*.igvm' 2>/dev/null |
                sort | head -n1 || true)"
        fi
    fi

    if [[ -z "$found_vars" ]]; then
        if [[ "$VED_SECURE_BOOT" -eq 1 ]]; then
            found_vars="$(find /usr/share/edk2 /usr/share/OVMF /usr/share/qemu /usr/share/edk2-ovmf \
                -maxdepth 2 -type f -name 'OVMF_VARS*secboot*' \
                ! -name '*.json' ! -name '*.pcrlock' 2>/dev/null | sort | head -n1 || true)"
        else
            found_vars="$(find /usr/share/edk2 /usr/share/OVMF /usr/share/qemu /usr/share/edk2-ovmf \
                -maxdepth 2 -type f -name 'OVMF_VARS*' \
                ! -name '*secboot*' ! -name '*.json' ! -name '*.pcrlock' 2>/dev/null |
                sort | head -n1 || true)"
        fi
    fi

    [[ -n "$found_code" ]] || die "$(t missing_file "OVMF_CODE (install the OVMF/edk2 package)")"
    [[ -n "$found_vars" ]] || die "$(t missing_file "OVMF_VARS (install the OVMF/edk2 package)")"

    VED_OVMF_CODE="$found_code"
    VED_OVMF_VARS_TEMPLATE="$found_vars"
    VED_OVMF_CODE_FORMAT="$(ovmf_format_for "$VED_OVMF_CODE")"
    VED_OVMF_VARS_FORMAT="$(ovmf_format_for "$VED_OVMF_VARS_TEMPLATE")"

    debug "OVMF code: $VED_OVMF_CODE ($VED_OVMF_CODE_FORMAT)"
    debug "OVMF vars: $VED_OVMF_VARS_TEMPLATE ($VED_OVMF_VARS_FORMAT)"

    if [[ "$VED_SECURE_BOOT" -eq 1 ]]; then
        info "$(t secure_boot_enabled)"
    fi
}

create_temporary_nvram() {
    info "$(t creating_vars)"

    VED_VARS_TEMP="$(mktemp "$VED_VM_DIR/OVMF_VARS.XXXXXX")"
    cleanup_add_file "$VED_VARS_TEMP"
    cp -f "$VED_OVMF_VARS_TEMPLATE" "$VED_VARS_TEMP"
    chmod 644 "$VED_VARS_TEMP"
}

detect_render_nodes() {
    VED_RENDER_NODES=()

    if [[ "$VED_GL" == "0" ]]; then
        info "$(t gl_disabled)"
        return
    fi

    if [[ -n "$VED_RENDER_NODE" ]]; then
        [[ -c "$VED_RENDER_NODE" ]] ||
            die "$(t missing_file "$VED_RENDER_NODE")"
        VED_RENDER_NODES=("$VED_RENDER_NODE")
        info "$(t render_node "$VED_RENDER_NODE")"
        return
    fi

    if [[ -d /dev/dri ]]; then
        mapfile -t VED_RENDER_NODES < <(
            find /dev/dri -maxdepth 1 -type c -name 'renderD*' 2>/dev/null | sort
        )
    fi

    if ((${#VED_RENDER_NODES[@]} == 0)); then
        warn "$(t no_render_node)"
        VED_GL=0
        return
    fi

    debug "Render nodes: ${VED_RENDER_NODES[*]}"
}

usb_normalize() {
    local value="$1"
    value="${value,,}"
    value="${value#0x}"
    value="${value/:0x/:}"
    printf '%s' "$value"
}

usb_present() {
    local vendor="$1"
    local product="$2"
    local dev

    for dev in /sys/bus/usb/devices/*; do
        [[ -f "$dev/idVendor" && -f "$dev/idProduct" ]] || continue
        if [[ "$(<"$dev/idVendor")" == "$vendor" &&
            "$(<"$dev/idProduct")" == "$product" ]]; then
            return 0
        fi
    done

    return 1
}

reset_usb_device() {
    local vendor="$1"
    local product="$2"
    local identifier="$vendor:$product"
    local dev attempt

    info "$(t bluetooth_reset "$identifier")"

    for attempt in $(seq 1 30); do
        for dev in /sys/bus/usb/devices/*; do
            [[ -f "$dev/idVendor" && -f "$dev/idProduct" ]] || continue
            [[ "$(<"$dev/idVendor")" == "$vendor" ]] || continue
            [[ "$(<"$dev/idProduct")" == "$product" ]] || continue

            if [[ -w "$dev/authorized" ]]; then
                printf '0\n' >"$dev/authorized"
                sleep 2
                printf '1\n' >"$dev/authorized"
                info "$(t bluetooth_reset_done "$identifier")"
                return 0
            fi
        done
        sleep 1
    done

    warn "$(t bluetooth_not_found "$identifier")"
    return 1
}

reset_usb_devices() {
    local entry vendor product

    for entry in "${VED_BT_RESET[@]}"; do
        entry="$(usb_normalize "$entry")"
        if [[ ! "$entry" =~ ^[0-9a-f]{4}:[0-9a-f]{4}$ ]]; then
            warn "$(t usb_invalid "$entry")"
            continue
        fi
        vendor="${entry%%:*}"
        product="${entry##*:}"
        reset_usb_device "$vendor" "$product" || true
    done
}

usb_sysfs_label() {
    local dev="$1"
    local manufacturer product

    manufacturer="$(cat "$dev/manufacturer" 2>/dev/null || true)"
    product="$(cat "$dev/product" 2>/dev/null || true)"

    if [[ -n "$product" && -n "$manufacturer" ]]; then
        printf '%s %s' "$manufacturer" "$product"
    elif [[ -n "$product" ]]; then
        printf '%s' "$product"
    else
        printf '%s:%s' "$(<"$dev/idVendor")" "$(<"$dev/idProduct")"
    fi
}

usb_interface_classes() {
    local dev="$1"
    local base iface

    base="$(basename "$dev")"
    for iface in /sys/bus/usb/devices/"$base":*; do
        [[ -f "$iface/bInterfaceClass" ]] || continue
        printf '%s %s %s\n' \
            "$(<"$iface/bInterfaceClass")" \
            "$(cat "$iface/bInterfaceSubClass" 2>/dev/null || true)" \
            "$(cat "$iface/bInterfaceProtocol" 2>/dev/null || true)"
    done
}

usb_is_webcam() {
    local classes
    classes="$(usb_interface_classes "$1")" || true
    [[ "$classes" == *"0e "* ]]
}

usb_is_bluetooth() {
    local classes
    classes="$(usb_interface_classes "$1")" || true
    [[ "$classes" == *"e0 01 01"* ]]
}

usb_is_android() {
    local dev="$1"
    local vendor name classes

    vendor="$(<"$dev/idVendor")"
    name="$(usb_sysfs_label "$dev")"

    case "$vendor" in
        18d1|04e8|22d9|2717|2718|2a70|2b4c|12d1|0bb4|1004|0fce|22b8|0421|04c5|0e8d|05c6)
            return 0
            ;;
    esac

    case "${name,,}" in
        *oneplus*|*pixel*|*galaxy*|*redmi*|*poco*|*xiaomi*|*xperia*|*oppo*|*vivo*|*realme*|*motorola*|*nexus*|*android*)
            return 0
            ;;
    esac

    classes="$(usb_interface_classes "$dev")" || true
    [[ "$classes" == *"ff 42 01"* || "$classes" == *"06 01 01"* ]]
}

usb_add_device() {
    local id="$1"
    local opts="${2:-}"
    local key="${id,,}"
    local vendor="${id%%:*}"
    local product="${id##*:}"
    local existing

    for existing in "${VED_USB_ADDED[@]}"; do
        [[ "$existing" == "$key" ]] && return 1
    done
    VED_USB_ADDED+=("$key")

    if [[ -n "$opts" ]]; then
        VED_USB_ARGS+=(
            -device "usb-host,vendorid=0x$vendor,productid=0x$product,$opts"
        )
    else
        VED_USB_ARGS+=(
            -device "usb-host,vendorid=0x$vendor,productid=0x$product"
        )
    fi

    VED_USB_SUMMARY+=("$id")
    return 0
}

usb_confirm_android() {
    local name="$1"
    local answer

    if [[ "$VED_ASSUME_YES" -eq 1 || ! -t 0 ]]; then
        return 0
    fi

    answer="$(ask "$(t usb_offer_android "$name")" "y")"
    case "${answer,,}" in
        y|yes|s|si|sí) return 0 ;;
        *) return 1 ;;
    esac
}

usb_autodetect() {
    local dev vendor product id name

    for dev in /sys/bus/usb/devices/*; do
        [[ -f "$dev/idVendor" && -f "$dev/idProduct" ]] || continue

        vendor="$(<"$dev/idVendor")"
        product="$(<"$dev/idProduct")"

        [[ "$vendor" == "1d6b" ]] && continue
        [[ "$(cat "$dev/bDeviceClass" 2>/dev/null || true)" == "09" ]] && continue

        id="$vendor:$product"
        name="$(usb_sysfs_label "$dev")"

        if usb_is_webcam "$dev"; then
            if usb_add_device "$id" ""; then
                info "$(t usb_auto_webcam "$name")"
            fi
        elif usb_is_bluetooth "$dev"; then
            if usb_add_device "$id" "guest-reset=true,guest-resets-all=true"; then
                VED_BT_RESET+=("$id")
                info "$(t usb_auto_bluetooth "$name")"
            fi
        elif usb_is_android "$dev"; then
            if [[ "$VED_USB_AUTO" == "all" ]] || usb_confirm_android "$name"; then
                if usb_add_device "$id" ""; then
                    info "$(t usb_auto_android "$name")"
                fi
            else
                info "$(t usb_skipped "$name")"
            fi
        fi
    done
}

setup_usb() {
    local entry vendor product

    VED_USB_ARGS=()
    VED_USB_ADDED=()
    VED_USB_SUMMARY=()

    for entry in "${VED_USB_DEVICES[@]}"; do
        entry="$(usb_normalize "$entry")"
        if [[ ! "$entry" =~ ^[0-9a-f]{4}:[0-9a-f]{4}$ ]]; then
            warn "$(t usb_invalid "$entry")"
            continue
        fi

        vendor="${entry%%:*}"
        product="${entry##*:}"

        if ! usb_present "$vendor" "$product"; then
            warn "$(t usb_not_found "$entry")"
            continue
        fi

        if usb_add_device "$entry" ""; then
            info "$(t usb_passthrough "$entry")"
        fi
    done

    case "$VED_USB_AUTO" in
        none)
            info "$(t usb_auto_disabled)"
            ;;
        auto|all)
            usb_autodetect
            ;;
    esac
}

setup_audio() {
    local runtime="$VED_GUI_RUNTIME"
    local pulse_socket="$runtime/pulse/native"
    local pipewire_socket="$runtime/pipewire-0"
    local drivers
    local driver=""

    VED_AUDIO_ARGS=()

    drivers="$("$(qemu_binary)" -audiodev help 2>/dev/null || true)"

    if [[ -S "$pulse_socket" ]] && grep -qx 'pa' <<<"$drivers"; then
        driver="pa"
        VED_AUDIO_ARGS=(
            -audiodev "pa,id=audio0,server=unix:$pulse_socket"
        )
    elif [[ -S "$pipewire_socket" ]] && grep -qx 'pipewire' <<<"$drivers"; then
        driver="pipewire"
        VED_AUDIO_ARGS=(
            -audiodev "pipewire,id=audio0"
        )
    fi

    if [[ -z "$driver" ]]; then
        info "$(t audio_disabled)"
        return
    fi

    VED_AUDIO_ARGS+=(
        -device ich9-intel-hda
        -device hda-duplex,audiodev=audio0
    )
    info "$(t audio_enabled "$driver")"
}

setup_tpm() {
    local mode="${VED_TPM}"
    local dev=""
    local state_dir="$VED_VM_DIR/tpm-state"
    local control="$state_dir/swtpm.sock"
    local pidfile="$state_dir/swtpm.pid"

    VED_TPM_ARGS=()

    if [[ "$mode" == "auto" ]]; then
        if [[ -e /dev/tpmrm0 || -e /dev/tpm0 ]]; then
            mode="passthrough"
        elif have swtpm; then
            mode="swtpm"
        else
            mode="0"
        fi
    fi

    if [[ "$mode" == "1" ]]; then
        if [[ -e /dev/tpmrm0 || -e /dev/tpm0 ]]; then
            mode="passthrough"
        elif have swtpm; then
            mode="swtpm"
        else
            mode="0"
        fi
    fi

    case "$mode" in
        0|off)
            info "$(t tpm_disabled)"
            return
            ;;
        passthrough)
            if [[ -e /dev/tpmrm0 ]]; then
                dev="/dev/tpmrm0"
            elif [[ -e /dev/tpm0 ]]; then
                dev="/dev/tpm0"
            else
                warn "$(t tpm_missing)"
                return
            fi
            VED_TPM_ARGS=(
                -tpmdev "passthrough,id=tpm0,path=$dev,cancel-path=/dev/null"
                -device tpm-tis,tpmdev=tpm0
            )
            info "$(t tpm_passthrough)"
            ;;
        swtpm)
            have swtpm || {
                warn "$(t tpm_missing)"
                return
            }
            info "$(t creating_tpm)"
            mkdir -p "$state_dir"
            if [[ -f "$pidfile" ]] && kill -0 "$(<"$pidfile")" 2>/dev/null; then
                die "$(t tpm_in_use)"
            fi
            rm -f "$control" "$pidfile"
            swtpm socket \
                --tpm2 \
                --tpmstate "dir=$state_dir" \
                --ctrl "type=unixio,path=$control" \
                --pid "file=$pidfile" \
                --flags not-need-init,startup-clear \
                --daemon
            if [[ -f "$pidfile" ]]; then
                VED_SWTPM_PID="$(<"$pidfile")"
                cleanup_add_pid "$VED_SWTPM_PID"
            fi
            VED_TPM_ARGS=(
                -chardev "socket,id=chrtpm,path=$control"
                -tpmdev "emulator,id=tpm0,chardev=chrtpm"
                -device tpm-tis,tpmdev=tpm0
            )
            info "$(t tpm_swtpm)"
            ;;
        *)
            warn "$(t tpm_missing)"
            ;;
    esac
}
