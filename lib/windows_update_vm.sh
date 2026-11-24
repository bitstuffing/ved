# Closed-loop Windows Update that applies the update inside QEMU/KVM instead of
# rebooting the Linux host. Everything here is Bash: discovery is handled by
# lib/windows_update.sh, and the guest applies the staged MSU packages with DISM.

# Repeated here so standalone ShellCheck runs see the cross-file state.
: "${VED_ROOT:=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"

powershell_vm_arch() {
    if [[ -n "$VED_ARCH" && "$VED_ARCH" != "auto" ]]; then
        printf '%s\n' "$VED_ARCH"
        return 0
    fi
    case "$(uname -m)" in
        aarch64|arm64) printf 'aarch64\n' ;;
        *) printf 'x86_64\n' ;;
    esac
}

powershell_vm_partition_range() {
    local part="$1" info start size

    info="$(lsblk -b -nrpo START,SIZE "$part" 2>/dev/null | head -n1 || true)"
    read -r start size <<<"$info"
    [[ "$start" =~ ^[0-9]+$ && "$size" =~ ^[0-9]+$ ]] || return 1
    printf '%s %s\n' "$start" "$size"
}

# Build a raw FAT image containing the selected disk's EFI partition. A fallback
# BootX64/BootAA64 entry is added so OVMF can boot the copied BCD without any
# changes to the host's UEFI variables.
powershell_vm_esp_image() {
    local loader="$1" arch="$2"
    local part rel probe copy esp mounted source_size size_mib fallback own=0

    part="${loader%%|*}"
    rel="${loader#*|}"
    rel="${rel//\\//}"
    rel="${rel#/}"

    mounted="$(findmnt -nrno TARGET "$part" 2>/dev/null | head -n1 || true)"
    if [[ -n "$mounted" && -d "$mounted/EFI" ]]; then
        probe="$mounted"
    else
        probe="$VED_VM_DIR/windows-esp-vm"
        mkdir -p "$probe" || die "$(t windows_update_vm_bootloader_failed)"
        cleanup_add_dir "$probe"
        mount -o ro "$part" "$probe" 2>/dev/null ||
            die "$(t windows_update_vm_bootloader_failed)"
        own=1
        cleanup_add_mount "$probe"
    fi
    [[ -f "$probe/$rel" ]] || die "$(t windows_update_vm_bootloader_failed)"

    source_size="$(du -sm "$probe/EFI" 2>/dev/null | awk '{print $1}' || printf '64')"
    [[ "$source_size" =~ ^[0-9]+$ ]] || source_size=64
    size_mib=$((source_size + 32))
    ((size_mib < 64)) && size_mib=64
    ((size_mib > 1024)) && size_mib=1024

    esp="$(mktemp "$VED_VM_DIR/ved-vm-esp.XXXXXX")" ||
        die "$(t windows_update_vm_bootloader_failed)"
    cleanup_add_file "$esp"
    truncate -s "${size_mib}M" "$esp"
    mkfs.vfat -F 32 -n VEDWINESP "$esp" >/dev/null ||
        die "$(t windows_update_vm_bootloader_failed)"

    copy="$VED_VM_DIR/ved-vm-esp-copy"
    mkdir -p "$copy" || die "$(t windows_update_vm_bootloader_failed)"
    cleanup_add_dir "$copy"
    umount_path "$copy"
    mount -o loop "$esp" "$copy" ||
        die "$(t windows_update_vm_bootloader_failed)"
    cleanup_add_mount "$copy"

    cp -a "$probe/EFI" "$copy/" || die "$(t windows_update_vm_bootloader_failed)"
    if [[ "$arch" == "aarch64" ]]; then
        fallback="BootAA64.efi"
    else
        fallback="BootX64.efi"
    fi
    mkdir -p "$copy/EFI/Boot" ||
        die "$(t windows_update_vm_bootloader_failed)"
    cp -f "$probe/$rel" "$copy/EFI/Boot/$fallback" ||
        die "$(t windows_update_vm_bootloader_failed)"
    sync || true

    umount_path "$copy"
    if ((own)); then
        umount_path "$probe"
    fi
    printf '%s\n' "$esp"
}

# Turn qemu-img's human map output into decimal "offset length file_offset"
# rows that intersect the Windows partition. Rows with a backing file are
# unchanged base clusters and are intentionally ignored.
powershell_vm_changed_ranges() {
    local overlay="$1" map="$2" ranges="$3" part_start="$4" part_size="$5"
    local start length offset part_end cs cl ce ms me delta len file_offset rows=0

    qemu-img map --output=human "$overlay" >"$map" || return 1
    : >"$ranges" || return 1
    part_end=$((part_start + part_size))

    while read -r start length offset; do
        [[ "$start" =~ ^0x[0-9A-Fa-f]+$ ]] || continue
        [[ "$length" =~ ^0x[0-9A-Fa-f]+$ ]] || continue
        [[ "$offset" =~ ^0x[0-9A-Fa-f]+$ ]] || continue
        cs=$((16#${start#0x}))
        cl=$((16#${length#0x}))
        co=$((16#${offset#0x}))
        ce=$((cs + cl))
        ((ce <= part_start || cs >= part_end)) && continue
        ms=$((cs > part_start ? cs : part_start))
        me=$((ce < part_end ? ce : part_end))
        ((me > ms)) || continue
        delta=$((ms - cs))
        len=$((me - ms))
        file_offset=$((co + delta))
        printf '%s %s %s\n' "$ms" "$len" "$file_offset" >>"$ranges" || return 1
        rows=$((rows + 1))
    done < <(awk -v overlay="$overlay" '
        NR > 1 {
            file = $0
            sub(/^[^ ]+ +[^ ]+ +[^ ]+ +/, "", file)
            if (file == overlay) print $1, $2, $3
        }' "$map")

    printf '%s\n' "$rows"
}

# Save every original range before touching the disk. If this is interleaved
# with the merge, a failure in a later range would leave zero-filled holes for
# ranges that were never backed up.
powershell_vm_backup_ranges() {
    local backup="$1" ranges="$2"
    local offset length unused

    while read -r offset length unused; do
        [[ "$offset" =~ ^[0-9]+$ && "$length" =~ ^[0-9]+$ ]] || return 1
        dd if="$VED_DISK" of="$backup" bs=1M \
            iflag=skip_bytes,count_bytes oflag=seek_bytes \
            skip="$offset" seek="$offset" count="$length" \
            status=none conv=fsync || return 1
    done <"$ranges"
}

# Save the original bytes before overwriting them, so a failed or incomplete
# guest update can be reversed exactly. The backup is sparse and only the
# changed ranges are written.
powershell_vm_merge_overlay() {
    local overlay="$1" backup="$2" ranges="$3"
    local offset length file_offset count=0

    count="$(wc -l <"$ranges" 2>/dev/null || printf '0')"
    count="${count//[[:space:]]/}"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    info "$(t windows_update_vm_merging "$count")"

    powershell_vm_backup_ranges "$backup" "$ranges" || return 1

    while read -r offset length file_offset; do
        [[ "$offset" =~ ^[0-9]+$ && "$length" =~ ^[0-9]+$ &&
           "$file_offset" =~ ^[0-9]+$ ]] || return 1
        dd if="$overlay" of="$VED_DISK" bs=1M \
            iflag=skip_bytes,count_bytes oflag=seek_bytes \
            skip="$file_offset" seek="$offset" count="$length" \
            status=none conv=fsync || return 1
    done <"$ranges"
    sync || true
}

powershell_vm_restore_backup() {
    local backup="$1" ranges="$2"
    local offset length unused

    [[ -f "$backup" ]] || return 0
    while read -r offset length unused; do
        [[ "$offset" =~ ^[0-9]+$ && "$length" =~ ^[0-9]+$ ]] || continue
        dd if="$backup" of="$VED_DISK" bs=1M \
            iflag=skip_bytes,count_bytes oflag=seek_bytes \
            skip="$offset" seek="$offset" count="$length" \
            status=none conv=fsync || return 1
    done <"$ranges"
    sync || true
}

powershell_vm_remove_startup() {
    if ! mountpoint -q "$VED_WINDOWS_MOUNT" 2>/dev/null; then
        powershell_mount_partition "$VED_ROOT_PARTITION" "$VED_WINDOWS_MOUNT" ||
            return 1
    fi
    powershell_remove_windows_startup
}

powershell_update_vm() {
    local kb="${VED_UPDATE_KB:-}" plan="" helper plan_env discovery_log count=""
    local candidate="" packages="" boot_loader="" esp_image="" overlay="" backup=""
    local map_file="" ranges="" saved_disk="$VED_DISK" partition_info=""
    local part_disk="" disk_name="" part_start="" part_size="" disk_size=""
    local arch rows="0" status_file=""
    local qemu_rc=0 merged=0
    local saved_image="$VED_IMAGE" saved_guest="$VED_GUEST_OS" saved_arch="$VED_ARCH"
    local saved_storage="$VED_STORAGE_MODE" saved_boot="$VED_BOOT"
    local saved_menu="$VED_BOOT_MENU" saved_network="$VED_NETWORK"
    local saved_esp="$VED_ESP_IMAGE" saved_format="$VED_IMAGE_FORMAT"
    local saved_vars="$VED_VARS_TEMP"
    local -a saved_storage_opts=("${VED_STORAGE_OPTS[@]}")
    local -a helper_args=()

    if [[ -z "$saved_disk" && -n "$VED_ROOT_PARTITION" ]]; then
        local numbers disk num
        numbers="$(powershell_partition_disk_number "$VED_ROOT_PARTITION" 2>/dev/null || true)"
        read -r disk num <<<"$numbers"
        saved_disk="$disk"
    fi
    [[ -n "$saved_disk" ]] || die "$(t image_and_disk)"

    arch="$(powershell_vm_arch)"
    VED_ARCH="$arch"
    have qemu-img || die "$(t windows_update_vm_qemu_missing)"
    case "$arch" in
        aarch64) have qemu-system-aarch64 || die "$(t windows_update_vm_qemu_missing)" ;;
        *) have qemu-system-x86_64 || die "$(t windows_update_vm_qemu_missing)" ;;
    esac

    VED_WINDOWS_WRITE=1

    helper="$VED_ROOT/lib/windows_update.sh"
    helper_args=(--windows-root "$VED_WINDOWS_MOUNT" --stage-dir "$VED_UPDATE_STAGE_DIR")
    [[ -z "$kb" ]] || helper_args+=(--kb "$kb")

    if [[ "$VED_DRY_RUN" -eq 1 ]]; then
        info "$(t windows_update_vm_warning)"
        info "$(t dry_run)"
        print_command bash "$helper" "${helper_args[@]}" --plan-only
        printf '\n'
        print_command qemu-img create -f qcow2 -b "$saved_disk" -F raw \
            "$VED_VM_DIR/ved-update.qcow2"
        printf '\n'
        printf '%s\n' \
            '# QEMU/KVM would boot the copied ESP and the overlay with temporary OVMF vars.'
        printf '%s\n' '# No host reboot, BootNext change or UEFI boot-order change is performed.'
        return 0
    fi

    info "$(t windows_update_vm_warning)"
    confirm_key windows_update_vm_confirm 0 || {
        info "$(t aborted)"
        return 0
    }

    info "$(t windows_update_vm_discovering)"
    discovery_log="$VED_UPDATE_STAGE_DIR/ved-update-discovery.log"
    if ! bash "$helper" "${helper_args[@]}" 2>&1 | tee "$discovery_log"; then
        die "$(t windows_update_discovery_failed)"
    fi
    plan_env="$VED_UPDATE_STAGE_DIR/ved-update-plan.env"
    [[ -f "$plan_env" ]] || die "$(t windows_update_discovery_failed)"
    count="$(powershell_plan_value VED_UPDATE_PACKAGE_COUNT "$plan_env")"
    if [[ -z "$count" || "$count" == "0" ]]; then
        info "$(t windows_update_up_to_date)"
        return 0
    fi
    kb="$(powershell_plan_value VED_UPDATE_KB "$plan_env")"
    candidate="$(powershell_plan_value VED_UPDATE_CANDIDATE_VERSION "$plan_env")"
    packages="$(powershell_plan_value VED_UPDATE_PACKAGE_NAMES "$plan_env")"
    powershell_validate_auto_plan "$kb" "$candidate" "$packages"
    info "$(t windows_update_found "$kb" "$count")"

    rm -f "$VED_UPDATE_STAGE_DIR/ved-update-status.txt" \
        "$VED_UPDATE_STAGE_DIR/ved-auto-apply.log"
    powershell_write_auto_apply "$kb" "$candidate" "$packages" shutdown
    info "$(t windows_update_apply_ready "$VED_UPDATE_APPLY_SCRIPT")"

    # Byte offsets are relative to the whole disk, so a mapped/decrypted
    # partition device must not be used as the merge target.
    part_disk="$(lsblk -nrpo PKNAME "$VED_ROOT_PARTITION" 2>/dev/null | head -n1 || true)"
    disk_name="$(lsblk -nrpo NAME "$saved_disk" 2>/dev/null | head -n1 || true)"
    [[ -n "$part_disk" && -n "$disk_name" && "$disk_name" == "/dev/$part_disk" ]] ||
        die "$(t windows_update_vm_partition_failed)"

    partition_info="$(powershell_vm_partition_range "$VED_ROOT_PARTITION" 2>/dev/null || true)"
    read -r part_start part_size <<<"$partition_info"
    [[ "$part_start" =~ ^[0-9]+$ && "$part_size" =~ ^[0-9]+$ ]] ||
        die "$(t windows_update_vm_partition_failed)"
    disk_size="$(lsblk -b -nrpo SIZE "$saved_disk" 2>/dev/null | head -n1 || true)"
    [[ "$disk_size" =~ ^[0-9]+$ ]] ||
        die "$(t windows_update_vm_partition_failed)"

    sync || true
    umount_path "$VED_WINDOWS_MOUNT"

    boot_loader="$(powershell_windows_bootloader "$saved_disk" 2>/dev/null || true)"
    [[ -n "$boot_loader" ]] || die "$(t windows_update_vm_bootloader_failed)"
    esp_image="$(powershell_vm_esp_image "$boot_loader" "$arch")"
    info "$(t windows_update_vm_esp_ready)"

    overlay="$VED_VM_DIR/ved-update.qcow2"
    backup="$VED_VM_DIR/ved-update-backup.img"
    map_file="$VED_VM_DIR/ved-update-map.txt"
    ranges="$VED_VM_DIR/ved-update-ranges.txt"
    cleanup_add_file "$overlay"
    cleanup_add_file "$backup"
    cleanup_add_file "$map_file"
    cleanup_add_file "$ranges"

    info "$(t windows_update_vm_creating_overlay "$saved_disk")"
    qemu-img create -f qcow2 -b "$saved_disk" -F raw "$overlay" >/dev/null ||
        die "$(t windows_update_vm_qemu_missing)"
    truncate -s "$disk_size" "$backup" ||
        die "$(t windows_update_vm_failed)"

    if [[ "$VED_DISPLAY_MODE" == "none" ]]; then
        detect_graphical_user_optional
    else
        detect_graphical_user
    fi

    # qemu_prepare() handles RAM/CPU/storage selection and temporary NVRAM.
    VED_DISK=""
    VED_IMAGE="$overlay"
    VED_IMAGE_FORMAT="qcow2"
    VED_GUEST_OS="windows"
    VED_STORAGE_MODE="persistent"
    VED_BOOT=1
    VED_BOOT_MENU=1
    VED_NETWORK="none"
    VED_ESP_IMAGE="$esp_image"

    info "$(t windows_update_vm_starting)"
    qemu_prepare && qemu_launch || qemu_rc=$?

    VED_DISK="$saved_disk"
    VED_IMAGE="$saved_image"
    VED_GUEST_OS="$saved_guest"
    VED_ARCH="$saved_arch"
    VED_STORAGE_MODE="$saved_storage"
    VED_STORAGE_OPTS=("${saved_storage_opts[@]}")
    VED_BOOT="$saved_boot"
    VED_BOOT_MENU="$saved_menu"
    VED_NETWORK="$saved_network"
    VED_ESP_IMAGE="$saved_esp"
    VED_IMAGE_FORMAT="$saved_format"
    VED_VARS_TEMP="$saved_vars"

    if ((qemu_rc != 0)); then
        powershell_vm_remove_startup >/dev/null 2>&1 || true
        die "$(t windows_update_vm_no_qemu)"
    fi

    rows="$(powershell_vm_changed_ranges "$overlay" "$map_file" "$ranges" \
        "$part_start" "$part_size" 2>/dev/null || true)"
    [[ "$rows" =~ ^[0-9]+$ ]] || rows=0

    if ! powershell_vm_merge_overlay "$overlay" "$backup" "$ranges"; then
        powershell_vm_restore_backup "$backup" "$ranges" >/dev/null 2>&1 || true
        powershell_vm_remove_startup >/dev/null 2>&1 || true
        die "$(t windows_update_vm_failed)"
    fi
    merged=1

    VED_WINDOWS_WRITE=0
    powershell_mount_partition "$VED_ROOT_PARTITION" "$VED_WINDOWS_MOUNT"
    status_file="$VED_WINDOWS_MOUNT/VEDUpdates/ved-update-status.txt"

    if [[ ! -f "$status_file" ]] ||
       ! grep -Eq 'SUCCESS|FAILED' "$status_file" 2>/dev/null; then
        info "$(t windows_update_vm_no_status)"
        powershell_vm_restore_backup "$backup" "$ranges" >/dev/null 2>&1 || true
        powershell_vm_remove_startup >/dev/null 2>&1 || true
        die "$(t windows_update_vm_failed)"
    fi
    if grep -Fq 'FAILED' "$status_file"; then
        info "$(t windows_update_vm_restoring)"
        powershell_vm_restore_backup "$backup" "$ranges" >/dev/null 2>&1 || true
        powershell_vm_remove_startup >/dev/null 2>&1 || true
        die "$(t windows_update_vm_failed)"
    fi

    ((merged == 1)) || die "$(t windows_update_vm_failed)"
    info "$(t windows_update_vm_success)"
    powershell_show_update_status
}
