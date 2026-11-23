backend_docker() {
    local base ref image_dir root default_command=""
    local -a passwd=()

    base="$(docker_storage_base)"
    mkdir -p "$base/images" "$base/rootfs" 2>/dev/null || true

    if [[ "$VED_DOCKER_LIST" -eq 1 ]]; then
        docker_registry_list_images
        return 0
    fi

    if [[ "$VED_DOCKER_PRUNE" -eq 1 ]]; then
        docker_registry_prune "$base"
        return 0
    fi

    ref="$(docker_normalize_image_ref "$VED_IMAGE" 2>/dev/null || true)"
    if [[ -z "$ref" ]]; then
        [[ -t 0 ]] || die "$(t docker_image_missing)"
        VED_IMAGE="$(ask "$(t docker_image_prompt)" "alpine:latest")"
        ref="$(docker_normalize_image_ref "$VED_IMAGE" 2>/dev/null || true)"
        [[ -n "$ref" ]] || die "$(t docker_image_missing)"
    fi

    if [[ -n "$VED_DISK" || -n "$VED_ROOT_PARTITION" ]]; then
        die "$(t docker_image_and_disk)"
    fi

    warn "$(t docker_chroot_warning)"

    docker_registry_require
    VED_DOCKER_IMAGE_REF="$ref"
    image_dir="$(docker_image_cache_dir "$ref")"

    docker_registry_pull "$ref" "$image_dir" ||
        die "$(t docker_pull_failed "$ref")"

    VED_GUEST_IMAGE_ENV=()
    docker_image_load_metadata "$image_dir" ||
        die "$(t docker_metadata_failed)"
    docker_image_check_platform

    select_session
    if [[ "$VED_SESSION" == "system" ]]; then
        die "$(t docker_system_unsupported)"
    fi

    # An explicit command always wins. Image ENTRYPOINT/CMD are only a
    # fallback for single-app sessions: init systems such as s6 (webtop)
    # refuse to run as anything but PID 1, so they must never replace an
    # interactive shell or VED's own desktop session selection.
    if [[ "$VED_SESSION" == "app" && -z "$VED_COMMAND" ]]; then
        default_command="$(docker_image_default_command 2>/dev/null || true)"
        if [[ -n "$default_command" ]]; then
            VED_COMMAND="$default_command"
        fi
    fi

    VED_CHROOT_WORKDIR=""
    # Docker images are ordinary rootfs directories here: no namespaces,
    # cgroups or container runtime are involved.
    VED_CHROOT_DISABLE_UTS=1

    VED_DOCKER_ROOTFS=""
    docker_rootfs_prepare "$image_dir" "$ref" ||
        die "$(t docker_rootfs_failed)"
    root="$VED_DOCKER_ROOTFS"
    [[ -n "$root" ]] || die "$(t docker_rootfs_failed)"
    VED_CHROOT_DIR="$root"

    if [[ -n "$VED_DOCKER_WORKDIR" && "$VED_DOCKER_WORKDIR" == /* ]]; then
        if [[ -d "$root$VED_DOCKER_WORKDIR" ]]; then
            VED_CHROOT_WORKDIR="$VED_DOCKER_WORKDIR"
        else
            warn "$(t docker_workdir_missing "$VED_DOCKER_WORKDIR")"
        fi
    fi

    chroot_prepare_graphical_session "$root"
    chroot_execute_session "$root"
}
