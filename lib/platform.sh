detect_platform() {
    [[ -r /etc/os-release ]] || die "$(t missing_file /etc/os-release)"

    # shellcheck source=/dev/null
    source /etc/os-release

    VED_DISTRO_ID="${ID:-unknown}"
    VED_DISTRO_NAME="${PRETTY_NAME:-${NAME:-$VED_DISTRO_ID}}"
    VED_DISTRO_LIKE="${ID_LIKE:-}"

    local fingerprint=" ${VED_DISTRO_ID,,} ${VED_DISTRO_LIKE,,} "

    case "$fingerprint" in
        *debian*|*ubuntu*|*linuxmint*|*pop*|*neon*|*kali*|*raspbian*)
            VED_PKG_FAMILY="debian"
            ;;
        *fedora*|*rhel*|*centos*|*nobara*|*rocky*|*almalinux*)
            VED_PKG_FAMILY="fedora"
            ;;
        *arch*|*manjaro*|*endeavouros*|*cachyos*)
            VED_PKG_FAMILY="arch"
            ;;
        *suse*|*sles*)
            VED_PKG_FAMILY="suse"
            ;;
        *alpine*)
            VED_PKG_FAMILY="alpine"
            ;;
        *void*)
            VED_PKG_FAMILY="void"
            ;;
        *)
            VED_PKG_FAMILY="unknown"
            ;;
    esac

    if [[ "$VED_PKG_FAMILY" == "unknown" ]]; then
        if have apt-get; then
            VED_PKG_FAMILY="debian"
        elif have dnf; then
            VED_PKG_FAMILY="fedora"
        elif have pacman; then
            VED_PKG_FAMILY="arch"
        elif have zypper; then
            VED_PKG_FAMILY="suse"
        elif have apk; then
            VED_PKG_FAMILY="alpine"
        elif have xbps-install; then
            VED_PKG_FAMILY="void"
        else
            VED_PKG_FAMILY="unknown"
        fi
    fi

    case "$VED_PKG_FAMILY" in
        debian) VED_PKG_MGR="apt-get" ;;
        fedora) VED_PKG_MGR="dnf" ;;
        arch) VED_PKG_MGR="pacman" ;;
        suse) VED_PKG_MGR="zypper" ;;
        alpine) VED_PKG_MGR="apk" ;;
        void) VED_PKG_MGR="xbps-install" ;;
        *) VED_PKG_MGR="" ;;
    esac

    debug "Distribution: $VED_DISTRO_NAME (family=$VED_PKG_FAMILY, manager=$VED_PKG_MGR)"

    if [[ -z "$VED_PKG_MGR" ]] || ! have "$VED_PKG_MGR"; then
        warn "$(t pkg_manager_unknown)"
    fi
}

package_name() {
    local logical="$1"

    case "$VED_PKG_FAMILY:$logical" in
        debian:qemu) printf '%s' "qemu-system-x86" ;;
        debian:qemu_aarch64) printf '%s' "qemu-system-arm" ;;
        debian:ovmf) printf '%s' "ovmf" ;;
        debian:aavmf) printf '%s' "qemu-efi-aarch64" ;;
        debian:virt_viewer) printf '%s' "virt-viewer" ;;
        debian:xephyr) printf '%s' "xserver-xephyr" ;;
        debian:dosfstools) printf '%s' "dosfstools" ;;
        debian:util_linux) printf '%s' "util-linux" ;;
        debian:coreutils) printf '%s' "coreutils" ;;
        debian:findutils) printf '%s' "findutils" ;;
        debian:systemd_container) printf '%s' "systemd-container" ;;
        debian:swtpm) printf '%s' "swtpm" ;;

        fedora:qemu) printf '%s' "qemu-system-x86" ;;
        fedora:qemu_aarch64) printf '%s' "qemu-system-aarch64" ;;
        fedora:ovmf) printf '%s' "edk2-ovmf" ;;
        fedora:aavmf) printf '%s' "edk2-aarch64" ;;
        fedora:virt_viewer) printf '%s' "virt-viewer" ;;
        fedora:xephyr) printf '%s' "xorg-x11-server-Xephyr" ;;
        fedora:dosfstools) printf '%s' "dosfstools" ;;
        fedora:util_linux) printf '%s' "util-linux" ;;
        fedora:coreutils) printf '%s' "coreutils" ;;
        fedora:findutils) printf '%s' "findutils" ;;
        fedora:systemd_container) printf '%s' "systemd-container" ;;
        fedora:swtpm) printf '%s' "swtpm" ;;

        arch:qemu) printf '%s' "qemu-full" ;;
        arch:qemu_aarch64) printf '%s' "qemu-full" ;;
        arch:ovmf) printf '%s' "ovmf" ;;
        arch:aavmf) printf '%s' "edk2-armvirt" ;;
        arch:virt_viewer) printf '%s' "virt-viewer" ;;
        arch:xephyr) printf '%s' "xorg-server-xephyr" ;;
        arch:dosfstools) printf '%s' "dosfstools" ;;
        arch:util_linux) printf '%s' "util-linux" ;;
        arch:coreutils) printf '%s' "coreutils" ;;
        arch:findutils) printf '%s' "findutils" ;;
        arch:systemd_container) printf '%s' "systemd" ;;
        arch:swtpm) printf '%s' "swtpm" ;;

        suse:qemu) printf '%s' "qemu-x86" ;;
        suse:qemu_aarch64) printf '%s' "qemu-arm" ;;
        suse:ovmf) printf '%s' "ovmf" ;;
        suse:aavmf) printf '%s' "qemu-uefi-aarch64" ;;
        suse:virt_viewer) printf '%s' "virt-viewer" ;;
        suse:xephyr) printf '%s' "xorg-x11-server-extra" ;;
        suse:dosfstools) printf '%s' "dosfstools" ;;
        suse:util_linux) printf '%s' "util-linux" ;;
        suse:coreutils) printf '%s' "coreutils" ;;
        suse:findutils) printf '%s' "findutils" ;;
        suse:systemd_container) printf '%s' "systemd-container" ;;
        suse:swtpm) printf '%s' "swtpm" ;;

        alpine:qemu) printf '%s' "qemu-system-x86_64" ;;
        alpine:qemu_aarch64) printf '%s' "qemu-system-aarch64" ;;
        alpine:ovmf) printf '%s' "ovmf" ;;
        alpine:aavmf) printf '%s' "qemu-efi-aarch64" ;;
        alpine:virt_viewer) printf '%s' "virt-viewer" ;;
        alpine:xephyr) printf '%s' "" ;;
        alpine:dosfstools) printf '%s' "dosfstools" ;;
        alpine:util_linux) printf '%s' "util-linux" ;;
        alpine:coreutils) printf '%s' "coreutils" ;;
        alpine:findutils) printf '%s' "findutils" ;;
        alpine:systemd_container) printf '%s' "" ;;
        alpine:swtpm) printf '%s' "swtpm" ;;

        void:qemu) printf '%s' "qemu" ;;
        void:qemu_aarch64) printf '%s' "qemu" ;;
        void:ovmf) printf '%s' "ovmf" ;;
        void:aavmf) printf '%s' "" ;;
        void:virt_viewer) printf '%s' "virt-viewer" ;;
        void:xephyr) printf '%s' "xorg-server-xephyr" ;;
        void:dosfstools) printf '%s' "dosfstools" ;;
        void:util_linux) printf '%s' "util-linux" ;;
        void:coreutils) printf '%s' "coreutils" ;;
        void:findutils) printf '%s' "findutils" ;;
        void:systemd_container) printf '%s' "" ;;
        void:swtpm) printf '%s' "swtpm" ;;

        *) printf '%s' "" ;;
    esac
}

logical_present() {
    local logical="$1"

    case "$logical" in
        qemu) have qemu-system-x86_64 ;;
        qemu_aarch64) have qemu-system-aarch64 ;;
        ovmf) ovmf_available ;;
        aavmf) aavmf_available ;;
        virt_viewer) have remote-viewer || have virt-viewer || have spicy ;;
        xephyr) have Xephyr ;;
        dosfstools) have mkfs.vfat ;;
        util_linux) have lsblk && have mountpoint && have runuser && have umount ;;
        coreutils) have truncate && have mktemp && have nproc && have chroot ;;
        findutils) have find ;;
        systemd_container) have systemd-nspawn ;;
        swtpm) have swtpm ;;
        *) return 1 ;;
    esac
}

install_packages() {
    local -a packages=("$@")
    ((${#packages[@]} > 0)) || return 0

    info "$(t installing_dependencies "${packages[*]}")"

    case "$VED_PKG_FAMILY" in
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update || die "$(t install_failed "apt-get update")"
            apt-get install -y --no-install-recommends "${packages[@]}" ||
                die "$(t install_failed "apt-get install")"
            ;;
        fedora)
            dnf install -y "${packages[@]}" || die "$(t install_failed "dnf install")"
            ;;
        arch)
            pacman -S --needed --noconfirm "${packages[@]}" ||
                die "$(t install_failed "pacman -S")"
            ;;
        suse)
            zypper --non-interactive install "${packages[@]}" ||
                die "$(t install_failed "zypper install")"
            ;;
        alpine)
            apk add "${packages[@]}" || die "$(t install_failed "apk add")"
            ;;
        void)
            xbps-install -Sy "${packages[@]}" ||
                die "$(t install_failed "xbps-install")"
            ;;
        *)
            die "$(t pkg_manager_unknown)"
            ;;
    esac
}

ensure_dependencies() {
    local -a required=() optional=()
    local logical package
    local -A seen=()

    case "$VED_BACKEND" in
        qemu)
            required=(qemu ovmf dosfstools util_linux coreutils findutils)
            optional=(virt_viewer swtpm)
            if [[ "$VED_ARCH" == "aarch64" ]]; then
                required+=(qemu_aarch64 aavmf)
            fi
            ;;
        chroot)
            required=(util_linux coreutils findutils)
            optional=(dosfstools xephyr)
            ;;
        nspawn)
            required=(systemd_container util_linux coreutils findutils)
            optional=(dosfstools xephyr)
            ;;
    esac

    for logical in "${required[@]}"; do
        if ! logical_present "$logical"; then
            package="$(package_name "$logical")"
            if [[ -n "$package" && -z "${seen[$package]:-}" ]]; then
                required+=("package:$package")
                seen["$package"]=1
            fi
        fi
    done

    local -a missing_packages=()
    for logical in "${required[@]}"; do
        if [[ "$logical" == package:* ]]; then
            missing_packages+=("${logical#package:}")
        fi
    done

    if ((${#missing_packages[@]} > 0)); then
        if [[ "$VED_NO_INSTALL" -eq 1 ]]; then
            die "$(t missing_packages "${missing_packages[*]}")"
        fi
        install_packages "${missing_packages[@]}"
    fi

    local -a optional_packages=()
    seen=()
    for logical in "${optional[@]}"; do
        if ! logical_present "$logical"; then
            package="$(package_name "$logical")"
            if [[ -n "$package" && -z "${seen[$package]:-}" ]]; then
                optional_packages+=("$package")
                seen["$package"]=1
            fi
        fi
    done

    if ((${#optional_packages[@]} > 0)) && [[ "$VED_NO_INSTALL" -eq 0 ]]; then
        (install_packages "${optional_packages[@]}") >/dev/null 2>&1 || true
    fi

    for logical in "${required[@]}"; do
        [[ "$logical" == package:* ]] && continue
        logical_present "$logical" ||
            die "$(t missing_packages "$logical")"
    done

    info "$(t dependencies_ready)"
}
