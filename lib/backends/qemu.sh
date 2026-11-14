qemu_escape() {
    printf '%s' "${1//,/,,}"
}

qemu_binary() {
    case "$VED_ARCH" in
        aarch64) printf '%s' "qemu-system-aarch64" ;;
        *) printf '%s' "qemu-system-x86_64" ;;
    esac
}

qemu_host_arch() {
    case "$(uname -m)" in
        aarch64|arm64) printf '%s' "aarch64" ;;
        *) printf '%s' "x86_64" ;;
    esac
}

qemu_machine() {
    case "$VED_ARCH" in
        aarch64) printf 'virt,accel=%s' "$1" ;;
        *) printf 'q35,accel=%s' "$1" ;;
    esac
}

detect_guest_arch() {
    local target base

    if [[ "$VED_ARCH" != "auto" ]]; then
        return 0
    fi

    target="${VED_IMAGE:-$VED_DISK}"
    base="${target##*/}"

    case "${base,,}" in
        *aarch64*|*arm64*|*raspberry*|*raspi*|*rpi*|*arm*) VED_ARCH="aarch64" ;;
        *) VED_ARCH="x86_64" ;;
    esac

    info "$(t arch_detected "$VED_ARCH")"
}

qemu_image_format() {
    local image="$1"
    local format=""
    local ext

    if have qemu-img; then
        format="$(qemu-img info "$image" 2>/dev/null |
            awk -F': ' '/^file format:/ {print $2; exit}' || true)"
    fi

    if [[ -z "$format" ]]; then
        ext="${image##*.}"
        case "${ext,,}" in
            qcow2|qcow|raw|vmdk|vdi|vhdx|vpc|iso) format="${ext,,}" ;;
            *) format="raw" ;;
        esac
    fi

    printf '%s' "$format"
}

qemu_select_accel() {
    local host_arch
    host_arch="$(qemu_host_arch)"

    if [[ "$VED_ARCH" != "$host_arch" ]]; then
        if [[ "$VED_ACCEL" == "kvm" ]]; then
            die "$(t kvm_missing)"
        fi
        VED_ACCEL_ACTUAL="tcg"
        if [[ "$VED_ACCEL" != "tcg" ]]; then
            info "$(t cross_arch_tcg "$VED_ARCH")"
        fi
        return
    fi

    case "$VED_ACCEL" in
        auto)
            if [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
                VED_ACCEL_ACTUAL="kvm"
                info "$(t kvm_enabled)"
            else
                VED_ACCEL_ACTUAL="tcg"
                warn "$(t kvm_missing)"
            fi
            ;;
        kvm)
            if [[ ! -c /dev/kvm || ! -r /dev/kvm || ! -w /dev/kvm ]]; then
                die "$(t kvm_missing)"
            fi
            VED_ACCEL_ACTUAL="kvm"
            info "$(t kvm_enabled)"
            ;;
        tcg)
            VED_ACCEL_ACTUAL="tcg"
            ;;
    esac
}

qemu_prepare() {
    if [[ -n "$VED_IMAGE" && -n "$VED_DISK" ]]; then
        die "$(t image_and_disk)"
    fi

    detect_guest_arch

    if [[ -n "$VED_IMAGE" ]]; then
        [[ -f "$VED_IMAGE" && -r "$VED_IMAGE" ]] ||
            die "$(t image_missing "$VED_IMAGE")"
        VED_IMAGE_FORMAT="$(qemu_image_format "$VED_IMAGE")"
        debug "Image format: $VED_IMAGE_FORMAT"
        detect_guest_os
    else
        select_disk
        assert_unmounted "$VED_DISK"
        detect_efi_partition
        select_efi_loader
        detect_guest_os
    fi

    select_memory
    select_cpus
    select_storage_mode

    detect_ovmf_files
    detect_render_nodes
    qemu_plan_display || true
    qemu_select_accel
    setup_tpm
    setup_audio
    setup_usb

    show_configuration

    create_temporary_nvram

    if [[ -n "$VED_IMAGE" ]]; then
        :
    else
        create_virtual_efi
    fi
}

qemu_display_candidates() {
    local node requested

    if [[ "$VED_DISPLAY_MODE" != "auto" ]]; then
        requested="$VED_DISPLAY_MODE"

        if [[ "$VED_GL" == "0" ]]; then
            case "$requested" in
                spice-gl) requested="spice" ;;
                gtk-gl) requested="gtk" ;;
            esac
        elif [[ "$VED_GL" == "1" ]] && ((${#VED_RENDER_NODES[@]} > 0)); then
            case "$requested" in
                spice) requested="spice-gl" ;;
                gtk) requested="gtk-gl" ;;
            esac
        fi

        case "$requested" in
            spice-gl|gtk-gl)
                if ((${#VED_RENDER_NODES[@]} > 0)); then
                    for node in "${VED_RENDER_NODES[@]}"; do
                        printf '%s:%s\n' "$requested" "$node"
                    done
                else
                    printf '%s:\n' "$requested"
                fi
                ;;
            *)
                printf '%s:\n' "$requested"
                ;;
        esac
        return
    fi

    if [[ "$VED_GUEST_OS" == "windows" ]]; then
        printf 'spice:\n'
        if [[ "$VED_GL" != "0" ]] && ((${#VED_RENDER_NODES[@]} > 0)); then
            for node in "${VED_RENDER_NODES[@]}"; do
                printf 'spice-gl:%s\n' "$node"
            done
        fi
    else
        if [[ "$VED_GL" != "0" ]] && ((${#VED_RENDER_NODES[@]} > 0)); then
            for node in "${VED_RENDER_NODES[@]}"; do
                printf 'spice-gl:%s\n' "$node"
            done
        fi
        printf 'spice:\n'
    fi

    if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        if [[ "$VED_GL" != "0" ]] && ((${#VED_RENDER_NODES[@]} > 0)); then
            for node in "${VED_RENDER_NODES[@]}"; do
                printf 'gtk-gl:%s\n' "$node"
            done
        fi
        printf 'gtk:\n'
    fi
}

qemu_plan_display() {
    local candidate mode node

    VED_DISPLAY_PLANNED_MODE=""
    VED_DISPLAY_PLANNED_NODE=""

    while IFS= read -r candidate; do
        mode="${candidate%%:*}"
        node="${candidate#*:}"

        if display_is_spice "$mode" && [[ ! -d "$VED_GUI_RUNTIME" ]]; then
            continue
        fi

        if [[ "$VED_DISPLAY_MODE" == "auto" ]] &&
            { display_is_spice "$mode" || [[ "$mode" == "vnc" ]]; }; then
            display_viewer_available "$mode" || continue
        fi

        VED_DISPLAY_PLANNED_MODE="$mode"
        VED_DISPLAY_PLANNED_NODE="$node"
        return 0
    done < <(qemu_display_candidates)

    return 1
}

qemu_disk_serial() {
    local name="${1:-$VED_DISK}"
    local disk_name
    local serial

    disk_name="$(basename "$name")"
    serial="VED-${disk_name//[^A-Za-z0-9]/-}"
    serial="${serial:0:20}"
    printf '%s' "$serial"
}

qemu_build_args() {
    local mode="$1"
    local node="$2"
    local cpu_model
    local serial
    local item
    local -a spice_agent=()

    if ! display_build_args "$mode" "$node"; then
        return 1
    fi

    if [[ "$VED_ACCEL_ACTUAL" == "kvm" ]]; then
        cpu_model="host"
    else
        cpu_model="max"
    fi

    VED_QEMU_ARGS=(
        -name "ved-$VED_GUEST_OS"
        -machine "$(qemu_machine "$VED_ACCEL_ACTUAL")"
        -cpu "$cpu_model"
        -smp "$VED_CPUS",sockets=1,cores="$VED_CPUS",threads=1
        -m "$VED_RAM"
        "${VED_STORAGE_OPTS[@]}"
        -drive "if=pflash,format=$VED_OVMF_CODE_FORMAT,readonly=on,file=$(qemu_escape "$VED_OVMF_CODE")"
        -drive "if=pflash,format=$VED_OVMF_VARS_FORMAT,file=$(qemu_escape "$VED_VARS_TEMP")"
    )

    if [[ -n "$VED_IMAGE" ]]; then
        serial="$(qemu_disk_serial "$VED_IMAGE")"
        if [[ "$VED_GUEST_OS" == "windows" && "$VED_ARCH" != "aarch64" ]]; then
            VED_QEMU_ARGS+=(
                -drive "file=$(qemu_escape "$VED_IMAGE"),format=$VED_IMAGE_FORMAT,if=none,id=ved-disk,cache=writeback,aio=threads"
                -device "nvme,drive=ved-disk,serial=$serial,bootindex=0"
            )
        else
            VED_QEMU_ARGS+=(
                -drive "file=$(qemu_escape "$VED_IMAGE"),format=$VED_IMAGE_FORMAT,if=none,id=ved-disk,cache=writeback,aio=threads"
                -device "virtio-blk-pci,drive=ved-disk,serial=$serial,bootindex=0"
            )
        fi
    else
        VED_QEMU_ARGS+=(
            -drive "file=$(qemu_escape "$VED_ESP_IMAGE"),format=raw,if=none,id=ved-esp,readonly=on"
            -device "virtio-blk-pci,drive=ved-esp,bootindex=0"
        )
        serial="$(qemu_disk_serial)"
        if [[ "$VED_ARCH" == "aarch64" ]]; then
            VED_QEMU_ARGS+=(
                -drive "file=$(qemu_escape "$VED_DISK"),format=raw,if=none,id=ved-disk,cache=none,aio=native"
                -device "virtio-blk-pci,drive=ved-disk,serial=$serial,bootindex=1"
            )
        else
            VED_QEMU_ARGS+=(
                -drive "file=$(qemu_escape "$VED_DISK"),format=raw,if=none,id=ved-disk,cache=none,aio=native"
                -device "nvme,drive=ved-disk,serial=$serial,bootindex=1"
            )
        fi
    fi

    VED_QEMU_ARGS+=("${VED_DISPLAY_ARGS[@]}")

    while IFS= read -r -d '' item; do
        spice_agent+=("$item")
    done < <(spice_agent_args "$mode")
    if ((${#spice_agent[@]} > 0)); then
        VED_QEMU_ARGS+=("${spice_agent[@]}")
    fi

    VED_QEMU_ARGS+=("${VED_AUDIO_ARGS[@]}")

    case "$VED_NETWORK" in
        user)
            if [[ "$VED_ARCH" == "aarch64" ]]; then
                VED_QEMU_ARGS+=(
                    -netdev user,id=net0
                    -device virtio-net-pci,netdev=net0
                )
            else
                VED_QEMU_ARGS+=(
                    -netdev user,id=net0
                    -device e1000e,netdev=net0
                )
            fi
            ;;
        none)
            ;;
        *)
            die "$(t network_invalid "$VED_NETWORK")"
            ;;
    esac

    VED_QEMU_ARGS+=(
        -device qemu-xhci
        -device usb-tablet
        "${VED_USB_ARGS[@]}"
        "${VED_TPM_ARGS[@]}"
        -device virtio-balloon-pci
        -device virtio-rng-pci
        -rtc clock=host,base=localtime
    )

    if [[ "$VED_BOOT_MENU" -eq 1 ]]; then
        VED_QEMU_ARGS+=(-boot menu=on)
    fi

    return 0
}

qemu_start_process() {
    local -a env_command=(env "TMPDIR=$VED_VM_DIR")
    local pulse_socket="${VED_GUI_RUNTIME:-}/pulse/native"
    local pulse_cookie="${VED_GUI_HOME:-}/.config/pulse/cookie"

    VED_QEMU_LOG="$VED_VM_DIR/qemu.log"

    if [[ -n "$VED_GUI_RUNTIME" ]]; then
        env_command+=(
            "XDG_RUNTIME_DIR=$VED_GUI_RUNTIME"
            "PIPEWIRE_RUNTIME_DIR=$VED_GUI_RUNTIME"
        )
        if [[ -S "$pulse_socket" ]]; then
            env_command+=("PULSE_SERVER=unix:$pulse_socket")
        fi
        if [[ -n "$VED_GUI_HOME" && -f "$pulse_cookie" ]]; then
            env_command+=("PULSE_COOKIE=$pulse_cookie")
        fi
    fi

    rm -f -- "$VED_SPICE_SOCKET"

    "${env_command[@]}" "$(qemu_binary)" "${VED_QEMU_ARGS[@]}" \
        >"$VED_QEMU_LOG" 2>&1 &

    VED_QEMU_PID="$!"
    debug "QEMU PID: $VED_QEMU_PID"
}

qemu_wait_ready() {
    local mode="$1"
    local attempt

    if display_is_spice "$mode"; then
        for ((attempt = 0; attempt < 100; attempt++)); do
            if ! kill -0 "$VED_QEMU_PID" 2>/dev/null; then
                return 1
            fi
            if [[ -S "$VED_SPICE_SOCKET" ]]; then
                return 0
            fi
            sleep 0.1
        done
        return 1
    fi

    sleep 2
    if kill -0 "$VED_QEMU_PID" 2>/dev/null; then
        return 0
    fi
    return 1
}

qemu_show_log_tail() {
    if [[ -f "$VED_QEMU_LOG" ]]; then
        warn "$(t qemu_log "$VED_QEMU_LOG")"
        tail -n 40 "$VED_QEMU_LOG" >&2 || true
    fi
}

qemu_attempt() {
    local mode="$1"
    local node="$2"
    local index

    info "$(t trying_display "$mode")"

    qemu_build_args "$mode" "$node" || return 1

    if [[ "$VED_DRY_RUN" -eq 1 ]]; then
        local -a dry_env=(env "TMPDIR=$VED_VM_DIR")
        local pulse_socket="${VED_GUI_RUNTIME:-}/pulse/native"
        local pulse_cookie="${VED_GUI_HOME:-}/.config/pulse/cookie"

        if [[ -n "$VED_GUI_RUNTIME" ]]; then
            dry_env+=(
                "XDG_RUNTIME_DIR=$VED_GUI_RUNTIME"
                "PIPEWIRE_RUNTIME_DIR=$VED_GUI_RUNTIME"
            )
            if [[ -S "$pulse_socket" ]]; then
                dry_env+=("PULSE_SERVER=unix:$pulse_socket")
            fi
            if [[ -n "$VED_GUI_HOME" && -f "$pulse_cookie" ]]; then
                dry_env+=("PULSE_COOKIE=$pulse_cookie")
            fi
        fi

        info "$(t dry_run)"
        print_command "${dry_env[@]}" "$(qemu_binary)" "${VED_QEMU_ARGS[@]}"
        printf '\n'
        return 2
    fi

    info "$(t starting_qemu)"
    qemu_start_process

    if display_is_spice "$mode"; then
        info "$(t waiting_spice)"
    fi

    if ! qemu_wait_ready "$mode"; then
        warn "$(t qemu_failed)"
        qemu_show_log_tail
        if kill -0 "$VED_QEMU_PID" 2>/dev/null; then
            kill "$VED_QEMU_PID" 2>/dev/null || true
            wait "$VED_QEMU_PID" 2>/dev/null || true
        fi
        VED_QEMU_PID=""
        return 1
    fi

    if display_is_spice "$mode"; then
        info "$(t spice_ready)"
        if [[ -n "$VED_GUI_USER" ]] && [[ -S "$VED_SPICE_SOCKET" ]]; then
            chown "$VED_GUI_UID:$VED_GUI_GID" "$VED_SPICE_SOCKET" 2>/dev/null || true
            chmod 660 "$VED_SPICE_SOCKET" 2>/dev/null || true
        fi
    elif [[ "$mode" == "vnc" ]]; then
        info "$(t vnc_listening)"
    fi

    if ((${#VED_BT_RESET[@]} > 0)); then
        sleep 3
        reset_usb_devices || true
    fi

    VED_DISPLAY_ACTUAL="$mode"

    info "$(t display_active "$mode")"
    if [[ "$VED_GL" == "1" && -n "$node" ]]; then
        info "$(t gl_active "$node")"
    fi

    if [[ "$VED_DISPLAY_NEEDS_VIEWER" -eq 0 ]]; then
        if [[ "$mode" == "none" ]]; then
            info "$(t headless_running)"
        else
            info "$(t qemu_running)"
        fi
        wait "$VED_QEMU_PID" 2>/dev/null || true
        VED_QEMU_PID=""
        info "$(t qemu_stopped)"
        return 0
    fi

    display_launch_viewer "$mode"

    if [[ -n "$VED_QEMU_PID" ]] && kill -0 "$VED_QEMU_PID" 2>/dev/null; then
        kill "$VED_QEMU_PID" 2>/dev/null || true
    fi
    wait "$VED_QEMU_PID" 2>/dev/null || true
    VED_QEMU_PID=""
    info "$(t qemu_stopped)"

    return 0
}

qemu_launch() {
    local -a candidates=()
    local candidate mode node rc

    mapfile -t candidates < <(qemu_display_candidates)

    for candidate in "${candidates[@]}"; do
        mode="${candidate%%:*}"
        node="${candidate#*:}"

        if display_is_spice "$mode" && [[ ! -d "$VED_GUI_RUNTIME" ]]; then
            warn "$(t runtime_missing "$VED_GUI_RUNTIME")"
            continue
        fi

        if [[ "$VED_DISPLAY_MODE" == "auto" ]] &&
            { display_is_spice "$mode" || [[ "$mode" == "vnc" ]]; }; then
            if ! display_viewer_available "$mode"; then
                debug "Skipping $mode: no viewer found"
                continue
            fi
        fi

        if qemu_attempt "$mode" "$node"; then
            return 0
        else
            rc=$?
        fi

        if [[ "$rc" -eq 2 ]]; then
            return 0
        fi

        warn "$(t display_fallback)"
    done

    die "$(t no_display)"
}

backend_qemu() {
    if [[ "$VED_DISPLAY_MODE" == "none" ]]; then
        detect_graphical_user_optional
    else
        detect_graphical_user
    fi

    qemu_prepare
    qemu_launch
}
