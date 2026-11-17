list_disks() {
    local name type ro
    while read -r name type ro; do
        [[ "$type" == "disk" ]] || continue
        [[ "$ro" == "1" ]] && continue
        case "$name" in
            /dev/loop*|/dev/zram*|/dev/ram*|/dev/sr*|/dev/dm-*|/dev/md*) continue ;;
        esac
        printf '%s\n' "$name"
    done < <(lsblk -dpno NAME,TYPE,RO 2>/dev/null)
}

select_disk() {
    local -a disks=()
    local disk_info option index
    local temp_disk

    if [[ -n "$VED_DISK" ]]; then
        [[ -b "$VED_DISK" ]] || die "$(t disk_missing "$VED_DISK")"
        return
    fi

    mapfile -t disks < <(list_disks)
    ((${#disks[@]} > 0)) || die "$(t no_disks)"

    echo
    info "$(t available_disks)"
    echo

    for index in "${!disks[@]}"; do
        temp_disk="${disks[$index]}"
        disk_info="$(lsblk -dnpo SIZE,MODEL,TRAN "$temp_disk" 2>/dev/null | tr -s ' ' || true)"
        printf '  %d) %s - %s\n' "$((index + 1))" "$temp_disk" "$disk_info"
    done

    echo

    while true; do
        option="$(ask "$(t select_disk)" "1")"
        if [[ "$option" =~ ^[0-9]+$ ]] &&
            ((option >= 1 && option <= ${#disks[@]})); then
            VED_DISK="${disks[$((option - 1))]}"
            break
        fi
        warn "$(t invalid_selection)"
    done

    echo
    info "$(t selected_disk)"
    printf '  %s\n' "$VED_DISK"
}

detect_efi_partition() {
    local esp_guid="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
    local part fstype

    if [[ -n "$VED_ESP" ]]; then
        [[ -b "$VED_ESP" ]] || die "$(t efi_missing "$VED_ESP")"
        return
    fi

    while read -r part fstype; do
        if [[ "${fstype,,}" == "$esp_guid" ]]; then
            VED_ESP="$part"
            break
        fi
    done < <(lsblk -nrpo NAME,PARTTYPE "$VED_DISK" 2>/dev/null)

    if [[ -z "$VED_ESP" ]]; then
        while read -r part fstype; do
            if [[ "${fstype,,}" == "vfat" ]]; then
                VED_ESP="$part"
                break
            fi
        done < <(lsblk -nrpo NAME,FSTYPE "$VED_DISK" 2>/dev/null)
    fi

    [[ -n "$VED_ESP" ]] || die "$(t no_efi "$VED_DISK")"

    info "$(t detected_efi)"
    printf '  %s\n' "$VED_ESP"
}

partition_looks_like_root() {
    local part="$1"
    local probe_dir="$2"
    local result=1

    mkdir -p "$probe_dir"
    if mount -o ro "$part" "$probe_dir" 2>/dev/null; then
        if [[ -f "$probe_dir/etc/os-release" || -x "$probe_dir/bin/sh" ]]; then
            result=0
        fi
        umount "$probe_dir" 2>/dev/null || true
    fi

    return "$result"
}

detect_root_partition() {
    local -a candidates=()
    local part fstype type part_info option index
    local probe_dir="$VED_VM_DIR/probe"
    local -a viable=()

    if [[ -n "$VED_ROOT_PARTITION" ]]; then
        [[ -b "$VED_ROOT_PARTITION" ]] ||
            die "$(t partition_missing "$VED_ROOT_PARTITION")"
        return
    fi

    [[ -n "$VED_DISK" ]] || die "$(t no_disks)"

    while read -r part fstype type; do
        [[ "$type" == "part" || "$type" == "lvm" ]] || continue
        case "${fstype,,}" in
            ext2|ext3|ext4|btrfs|xfs|f2fs|nilfs2)
                candidates+=("$part")
                ;;
        esac
    done < <(lsblk -nrpo NAME,FSTYPE,TYPE "$VED_DISK" 2>/dev/null)

    ((${#candidates[@]} > 0)) || die "$(t no_partitions "$VED_DISK")"

    mkdir -p "$probe_dir"
    cleanup_add_dir "$probe_dir"

    for part in "${candidates[@]}"; do
        if partition_looks_like_root "$part" "$probe_dir"; then
            viable+=("$part")
        fi
    done

    if ((${#viable[@]} == 0)); then
        viable=("${candidates[@]}")
    fi

    if ((${#viable[@]} == 1)); then
        VED_ROOT_PARTITION="${viable[0]}"
        return
    fi

    echo
    info "$(t available_partitions)"
    echo

    for index in "${!viable[@]}"; do
        part="${viable[$index]}"
        part_info="$(lsblk -dnpo SIZE,FSTYPE,LABEL "$part" 2>/dev/null | tr -s ' ' || true)"
        printf '  %d) %s - %s\n' "$((index + 1))" "$part" "$part_info"
    done

    echo

    while true; do
        option="$(ask "$(t select_partition)" "1")"
        if [[ "$option" =~ ^[0-9]+$ ]] &&
            ((option >= 1 && option <= ${#viable[@]})); then
            VED_ROOT_PARTITION="${viable[$((option - 1))]}"
            break
        fi
        warn "$(t invalid_selection)"
    done

    echo
    info "$(t selected_partition)"
    printf '  %s\n' "$VED_ROOT_PARTITION"
}

windows_mount_type() {
    if have ntfs-3g || have mount.ntfs; then
        printf 'ntfs'
    elif grep -qw ntfs3 /proc/filesystems 2>/dev/null; then
        printf 'ntfs3'
    else
        return 1
    fi
}

windows_partition_candidates() {
    local part fstype label
    while read -r part fstype label; do
        [[ -n "$part" ]] || continue
        case "${fstype,,}" in
            ntfs|ntfs3|bitlocker|*bitlocker*) printf '%s\n' "$part" ;;
            '')
                case "${label,,}" in
                    *windows*|*os*|*system*) printf '%s\n' "$part" ;;
                esac
                ;;
        esac
    done < <(lsblk -nrpo NAME,FSTYPE,LABEL "$VED_DISK" 2>/dev/null)
}

detect_windows_partition() {
    local -a candidates=() viable=()
    local part part_info option index mount_type
    local probe_dir="$VED_VM_DIR/windows-probe"

    if [[ -n "$VED_ROOT_PARTITION" ]]; then
        [[ -b "$VED_ROOT_PARTITION" ]] ||
            die "$(t partition_missing "$VED_ROOT_PARTITION")"
        return
    fi

    [[ -n "$VED_DISK" ]] || die "$(t no_disks)"

    mapfile -t candidates < <(windows_partition_candidates)
    ((${#candidates[@]} > 0)) || die "$(t windows_no_partition "$VED_DISK")"

    mount_type="$(windows_mount_type || true)"

    if [[ -n "$mount_type" ]]; then
        mkdir -p "$probe_dir"
        cleanup_add_dir "$probe_dir"
        for part in "${candidates[@]}"; do
            umount_path "$probe_dir"
            if mount -t "$mount_type" -o ro "$part" "$probe_dir" 2>/dev/null; then
                if [[ -d "$probe_dir/Windows/System32" ||
                    -d "$probe_dir/windows/system32" ]]; then
                    viable+=("$part")
                fi
                umount "$probe_dir" 2>/dev/null || true
            fi
        done
    fi

    ((${#viable[@]} > 0)) || viable=("${candidates[@]}")

    if ((${#viable[@]} == 1)); then
        VED_ROOT_PARTITION="${viable[0]}"
        return
    fi

    echo
    info "$(t windows_partitions)"
    echo

    for index in "${!viable[@]}"; do
        part="${viable[$index]}"
        part_info="$(lsblk -dnpo SIZE,FSTYPE,LABEL "$part" 2>/dev/null | tr -s ' ' || true)"
        printf '  %d) %s - %s\n' "$((index + 1))" "$part" "$part_info"
    done

    echo

    while true; do
        option="$(ask "$(t windows_select_partition)" "1")"
        if [[ "$option" =~ ^[0-9]+$ ]] &&
            ((option >= 1 && option <= ${#viable[@]})); then
            VED_ROOT_PARTITION="${viable[$((option - 1))]}"
            break
        fi
        warn "$(t invalid_selection)"
    done

    echo
    info "$(t windows_selected_partition)"
    printf '  %s\n' "$VED_ROOT_PARTITION"
}

assert_unmounted() {
    local device="$1"
    local mounted

    mounted="$(lsblk -nrpo MOUNTPOINT "$device" 2>/dev/null | grep -E '\S' || true)"
    if [[ -n "$mounted" ]]; then
        printf '%s\n' "$mounted" >&2
        lsblk -o NAME,MOUNTPOINTS "$device" >&2
        die "$(t mounted_disk)"
    fi
}

mount_path() {
    local source="$1"
    local target="$2"
    local options="${3:-ro}"

    mkdir -p "$target"

    local fstype parttype
    fstype="$(lsblk -nrpo FSTYPE "$source" 2>/dev/null | head -n1 || true)"
    parttype="$(lsblk -nrpo PARTTYPE "$source" 2>/dev/null | head -n1 || true)"

    if [[ -n "$parttype" ]]; then
        case "${parttype,,}" in
            *crypto*|*luks*|4f68bce3-e8cd-4db1-96e7-fbcaf984b709)
                die "$(t luks_partition "$source")"
                ;;
            *lvm*|e6d6d379-f507-44c2-a23c-238f2a3df928)
                die "$(t lvm_partition "$source")"
                ;;
        esac
    fi

    if [[ -n "$fstype" && "$fstype" != "swap" ]]; then
        mount -t "$fstype" -o "$options" "$source" "$target"
    else
        mount -o "$options" "$source" "$target"
    fi
    cleanup_add_mount "$target"
}

umount_path() {
    local target="$1"
    if mountpoint -q "$target" 2>/dev/null; then
        sync
        umount "$target" 2>/dev/null || umount -l "$target" 2>/dev/null || true
    fi
}

list_efi_loaders() {
    local mount_point="$1"

    find "$mount_point/EFI" \
        -type f \
        -iname '*.efi' \
        ! -path "$mount_point/EFI/BOOT/*" \
        ! -iname 'gcdia32.efi' \
        ! -iname 'gcdx64.efi' \
        ! -iname 'grubia32.efi' \
        ! -iname 'shimia32.efi' \
        ! -iname 'mmia32.efi' \
        ! -iname 'mmx64.efi' \
        ! -iname 'memtest.efi' \
        ! -iname 'bootmgr.efi' \
        ! -iname 'SecureBootRecovery.efi' \
        -print 2>/dev/null |
        sed "s|^$mount_point/||" |
        sort -f
}

mount_source_efi() {
    [[ -b "$VED_ESP" ]] || die "$(t efi_missing "$VED_ESP")"

    mkdir -p "$VED_SOURCE_MOUNT"
    cleanup_add_dir "$VED_SOURCE_MOUNT"
    umount_path "$VED_SOURCE_MOUNT"

    info "$(t mounting_source)"
    mount_path "$VED_ESP" "$VED_SOURCE_MOUNT" "ro"
}

select_efi_loader() {
    local -a candidates=()
    local option index

    mount_source_efi

    if [[ "$VED_EFI_LOADER_SET" -eq 1 ]]; then
        if [[ -z "$VED_EFI_LOADER" ]]; then
            return
        fi
        valid_efi_loader_path "$VED_EFI_LOADER" ||
            die "$(t invalid_efi_loader "$VED_EFI_LOADER")"
        if [[ ! -f "$VED_SOURCE_MOUNT/$VED_EFI_LOADER" ]]; then
            die "$(t loader_missing "$VED_SOURCE_MOUNT/$VED_EFI_LOADER")"
        fi
        return
    fi

    mapfile -t candidates < <(list_efi_loaders "$VED_SOURCE_MOUNT")

    if [[ "${#candidates[@]}" -eq 0 ]]; then
        warn "$(t no_loaders "$VED_SOURCE_MOUNT/EFI")"
        VED_EFI_LOADER=""
        return
    fi

    if [[ ! -t 0 ]]; then
        VED_EFI_LOADER="${candidates[0]}"
        return
    fi

    echo
    info "$(t efi_loaders)"
    echo

    for index in "${!candidates[@]}"; do
        printf '  %d) %s\n' "$((index + 1))" "${candidates[$index]}"
    done

    echo
    printf '  0) %s\n' "$(t uefi_menu)"
    echo

    while true; do
        option="$(ask "$(t select_loader)" "1")"
        if [[ "$option" =~ ^[0-9]+$ ]] &&
            ((option >= 0 && option <= ${#candidates[@]})); then
            break
        fi
        warn "$(t invalid_selection)"
    done

    if ((option == 0)); then
        VED_EFI_LOADER=""
        return
    fi

    VED_EFI_LOADER="${candidates[$((option - 1))]}"
    echo
    info "$(t selected_loader)"
    printf '  %s\n' "$VED_EFI_LOADER"
}

detect_guest_os() {
    if [[ "$VED_GUEST_OS" != "auto" ]]; then
        info "$(t guest_os_forced "$VED_GUEST_OS")"
        return
    fi

    if [[ -n "$VED_EFI_LOADER" ]]; then
        case "${VED_EFI_LOADER,,}" in
            *microsoft*|*bootmgfw*) VED_GUEST_OS="windows" ;;
            *) VED_GUEST_OS="linux" ;;
        esac
        info "$(t "guest_os_$VED_GUEST_OS")"
        return
    fi

    if [[ -z "$VED_IMAGE" ]] && mountpoint -q "$VED_SOURCE_MOUNT" 2>/dev/null &&
        [[ -d "$VED_SOURCE_MOUNT/EFI/Microsoft" ]]; then
        VED_GUEST_OS="windows"
    else
        VED_GUEST_OS="linux"
    fi
    info "$(t "guest_os_$VED_GUEST_OS")"
}

create_virtual_efi() {
    local size_mib=128
    local source_size

    info "$(t creating_esp)"

    source_size="$(du -sm "$VED_SOURCE_MOUNT" 2>/dev/null | awk '{print $1}' || printf '64')"
    if [[ "$source_size" =~ ^[0-9]+$ ]]; then
        size_mib=$((source_size + 64))
    fi
    if ((size_mib < 64)); then
        size_mib=64
    fi
    if ((size_mib > 1024)); then
        size_mib=1024
    fi

    VED_ESP_IMAGE="$(mktemp /tmp/ved-esp.XXXXXX)"
    cleanup_add_file "$VED_ESP_IMAGE"

    truncate -s "${size_mib}M" "$VED_ESP_IMAGE"
    mkfs.vfat -F 32 -n QEMU_EFI "$VED_ESP_IMAGE" >/dev/null

    mkdir -p "$VED_COPY_MOUNT"
    cleanup_add_dir "$VED_COPY_MOUNT"
    umount_path "$VED_COPY_MOUNT"
    mount -o loop "$VED_ESP_IMAGE" "$VED_COPY_MOUNT"
    cleanup_add_mount "$VED_COPY_MOUNT"

    info "$(t copying_efi)"
    cp -a "$VED_SOURCE_MOUNT/EFI" "$VED_COPY_MOUNT/"

    if [[ -n "$VED_EFI_LOADER" ]]; then
        mkdir -p "$VED_COPY_MOUNT/EFI/BOOT"

        if [[ ! -f "$VED_COPY_MOUNT/$VED_EFI_LOADER" ]]; then
            die "$(t loader_missing "$VED_COPY_MOUNT/$VED_EFI_LOADER")"
        fi

        cp -f "$VED_COPY_MOUNT/$VED_EFI_LOADER" "$VED_COPY_MOUNT/EFI/BOOT/BOOTX64.EFI"
    fi

    sync
    umount_path "$VED_COPY_MOUNT"
    umount_path "$VED_SOURCE_MOUNT"
}
