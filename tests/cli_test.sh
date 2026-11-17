#!/usr/bin/env bash
# Non-privileged CLI regression tests. These must never mount devices or invoke sudo.
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
VED="$PROJECT_ROOT/ved"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf -- "$TMPDIR_TEST"' EXIT

passed=0
failed=0

pass() {
    printf 'ok - %s\n' "$1"
    ((passed += 1))
}

fail() {
    printf 'not ok - %s\n' "$1" >&2
    failed=1
}

run_directory_isolation() (
    # shellcheck source=../lib/core.sh
    source "$PROJECT_ROOT/lib/core.sh"
    t() { printf '%s' "$1"; }

    VED_RUNTIME_BASE="$TMPDIR_TEST/runtime"
    initialize_run_directory
    local first_run="$VED_RUN_DIR"
    local first_vm="$VED_VM_DIR"

    initialize_run_directory
    local second_run="$VED_RUN_DIR"
    local second_vm="$VED_VM_DIR"

    [[ "$first_run" != "$second_run" ]]
    [[ -d "$first_vm" && -d "$second_vm" ]]

    cleanup_run >/dev/null
    [[ ! -e "$first_run" && ! -e "$second_run" ]]
)

run_windows_helpers() (
    # shellcheck source=../lib/core.sh
    source "$PROJECT_ROOT/lib/core.sh"
    t() { printf '%s' "$1"; }
    # shellcheck source=../lib/disks.sh
    source "$PROJECT_ROOT/lib/disks.sh"
    # shellcheck source=../lib/backends/powershell.sh
    source "$PROJECT_ROOT/lib/backends/powershell.sh"

    local test_user test_uid test_gid
    test_user="$(id -un)"
    if [[ "$test_user" == "root" ]]; then
        test_user="$(awk -F: '$1 != "root" && $3 != 0 && $6 != "" && $6 != "/" { print $1; exit }' /etc/passwd)"
    fi
    [[ -n "$test_user" ]]
    test_uid="$(id -u "$test_user")"
    test_gid="$(id -g "$test_user")"

    VED_GUI_USER=""
    VED_GUI_UID=""
    VED_GUI_GID=""
    [[ "$(powershell_mount_options ro)" == "ro,nosuid,nodev" ]]
    VED_GUI_USER="$test_user"
    VED_GUI_UID="$test_uid"
    VED_GUI_GID="$test_gid"
    [[ "$(powershell_mount_options rw)" == "rw,nosuid,nodev,uid=$test_uid,gid=$test_gid" ]]

    local expected_home
    expected_home="$(getent passwd "$test_user" | cut -d: -f6)"
    powershell_gui_runner "$VED_GUI_USER"
    [[ "$PWSH_RUNNER_HOME" == "$expected_home" ]]
    [[ " ${PWSH_RUNNER[*]} " == *" env -i "* ]]
    [[ " ${PWSH_RUNNER[*]} " == *" HOME=$expected_home "* ]]
    [[ " ${PWSH_RUNNER[*]} " == *" USER=$VED_GUI_USER "* ]]
    [[ " ${PWSH_RUNNER[*]} " == *" LOGNAME=$VED_GUI_USER "* ]]
    [[ " ${PWSH_RUNNER[*]} " == *" XDG_DATA_HOME=$expected_home/.local/share "* ]]
    [[ " ${PWSH_RUNNER[*]} " == *" XDG_CONFIG_HOME=$expected_home/.config "* ]]
    if powershell_gui_runner root; then
        return 1
    fi

    VED_WINDOWS_DRIVE="D"
    VED_WINDOWS_MOUNT="/mnt/windows-test"
    VED_RUN_DIR="$TMPDIR_TEST"
    local script_dir="$TMPDIR_TEST/gui-scripts"
    mkdir -p "$script_dir"
    VED_WINDOWS_SCRIPT_DIR="$script_dir"
    [[ "$(powershell_script_dir)" == "$script_dir" ]]
    VED_WINDOWS_SCRIPT_DIR=""
    [[ "$(powershell_script_dir)" == "$TMPDIR_TEST" ]]
    VED_WINDOWS_SCRIPT_DIR="$script_dir"
    local profile
    profile="$(powershell_write_profile)"
    [[ "$profile" == "$script_dir/ved-profile.ps1" ]]
    grep -Fq "New-PSDrive -Name 'D'" "$profile"
    grep -Fq "Set-Location 'D:" "$profile"
    grep -Fq "Set-PSReadLineOption -HistorySavePath" "$profile"
    grep -Fq "'$script_dir/PSReadLine_history.txt'" "$profile"
    ! grep -Fq '/run/ved/' "$profile"

    local history
    history="$(powershell_prepare_history)"
    [[ "$history" == "$script_dir/PSReadLine_history.txt" ]]
    [[ -f "$history" ]]
    [[ "$(stat -c '%a' "$history")" == "600" ]]

    lsblk() {
        local args=" $* "
        if [[ "$args" == *" MOUNTPOINT "* ]]; then
            printf '%s\n' '/mnt/existing'
            return 0
        fi
        printf '%s\n' \
            '/dev/nvme0n1p1 vfat EFI' \
            '/dev/nvme0n1p2 ntfs OS' \
            '/dev/nvme0n1p3 ext4 Linux' \
            '/dev/nvme0n1p4 BitLocker Data'
    }
    VED_DISK="/dev/nvme0n1"
    local -a candidates=()
    mapfile -t candidates < <(windows_partition_candidates)
    [[ "${#candidates[@]}" -eq 2 ]]
    [[ "${candidates[0]}" == "/dev/nvme0n1p2" ]]
    [[ "${candidates[1]}" == "/dev/nvme0n1p4" ]]
    [[ "$(powershell_existing_mountpoint /dev/nvme0n1p2)" == "/mnt/existing" ]]

    local fake_win="$TMPDIR_TEST/fake-win"
    mkdir -p "$fake_win"
    if powershell_is_hibernated "$fake_win"; then
        return 1
    fi
    : >"$fake_win/hiberfil.sys"
    powershell_is_hibernated "$fake_win"

    have() { [[ "$1" == "pwsh" ]]; }
    VED_DRY_RUN=1
    VED_GUI_USER=""
    local dry_output
    dry_output="$(powershell_run_pwsh "$profile" "")"
    [[ "$dry_output" == *"pwsh -NoLogo -NoProfile -NoExit -File $script_dir/ved-profile.ps1"* ]]

    dry_output="$(powershell_run_pwsh "$profile" 'Get-Location')"
    [[ "$dry_output" == *"-File $script_dir/ved-command.ps1"* ]]
    grep -Fq 'Get-Location' "$script_dir/ved-command.ps1"

    VED_GUI_USER="$test_user"
    dry_output="$(powershell_run_pwsh "$profile" "")"
    [[ "$dry_output" == *"HOME=$expected_home"* ]]
    [[ "$dry_output" != *"HOME=/root"* ]]

    dry_output="$(powershell_run_cmd "")"
    [[ "$dry_output" == *"HOME=$expected_home"* ]]
    [[ "$dry_output" == *"WINEPREFIX=$expected_home/.local/share/ved/wine"* ]]
    [[ "$dry_output" != *"HOME=/root"* ]]
)

run_powershell_hint() (
    # shellcheck source=../lib/core.sh
    source "$PROJECT_ROOT/lib/core.sh"
    # shellcheck source=../lib/platform.sh
    source "$PROJECT_ROOT/lib/platform.sh"
    t() { printf '%s' "$1"; }

    VED_PKG_FAMILY="fedora"
    local output
    output="$(powershell_install_hint)"
    [[ "$output" == *"sudo dnf install -y powershell"* ]]
    [[ "$output" == *"--shell cmd"* ]]

    VED_PKG_FAMILY="debian"
    output="$(powershell_install_hint)"
    [[ "$output" == *"sudo apt-get install -y powershell"* ]]

    VED_PKG_FAMILY="arch"
    output="$(powershell_install_hint)"
    [[ "$output" == *"powershell-bin"* ]]
)

run_locale_messages() (
    # shellcheck source=../lib/i18n.sh
    source "$PROJECT_ROOT/lib/i18n.sh"
    VED_ROOT="$PROJECT_ROOT"

    check_keys() {
        local key
        for key in backend_powershell shell_user_invalid windows_temp_failed; do
            [[ "$(t "$key")" != "$key" ]]
        done
    }

    VED_LANG=en
    ved_i18n_load
    check_keys

    VED_LANG=es
    ved_i18n_load
    check_keys
)

run_cli_parsing() (
    # shellcheck source=../lib/core.sh
    source "$PROJECT_ROOT/lib/core.sh"
    t() { printf '%s' "$1"; }

    parse_cli --backend PWSH --shell CMD --windows-drive d --windows-write
    [[ "$VED_BACKEND" == "powershell" ]]
    [[ "$VED_SHELL" == "cmd" ]]
    [[ "$VED_WINDOWS_DRIVE" == "D" ]]
    [[ "$VED_WINDOWS_WRITE" -eq 1 ]]

    parse_cli --backend windows --shell powershell --windows-ro --windows-drive z
    [[ "$VED_SHELL" == "pwsh" ]]
    [[ "$VED_WINDOWS_DRIVE" == "Z" ]]
    [[ "$VED_WINDOWS_WRITE" -eq 0 ]]
)

run_ved() {
    local name="$1"
    local expected_status="$2"
    local expected_text="$3"
    shift 3

    local output="$TMPDIR_TEST/$name.out"
    local status

    if env LC_ALL=C LANG=C "$VED" "$@" >"$output" 2>&1; then
        status=0
    else
        status=$?
    fi

    if [[ "$status" != "$expected_status" ]]; then
        printf 'Expected status %s, got %s. Output:\n' "$expected_status" "$status" >&2
        while IFS= read -r line || [[ -n "$line" ]]; do
            printf '%s\n' "$line" >&2
        done <"$output"
        fail "$name"
        return
    fi

    if ! grep -Fq -- "$expected_text" "$output"; then
        printf 'Expected output to contain %q. Output:\n' "$expected_text" >&2
        while IFS= read -r line || [[ -n "$line" ]]; do
            printf '%s\n' "$line" >&2
        done <"$output"
        fail "$name"
        return
    fi

    pass "$name"
}

run_ved version 0 'ved 2.1.0' --version
run_ved help 0 'Usage:' --help
run_ved unsupported_language 0 'unsupported language "zz"; using English.' --lang zz --version
run_ved unknown_option 1 'Unknown option: --not-an-option' --not-an-option
run_ved invalid_backend 1 'Invalid backend: unsupported' --backend unsupported --version
run_ved invalid_gui_target 1 'Invalid display target: detached' --gui detached --version
run_ved gui_target_alias 0 'ved 2.1.0' --gui-target host --version
run_ved powershell_backend_alias 0 'ved 2.1.0' --backend pwsh --version
run_ved powershell_backend_alias_windows 0 'ved 2.1.0' --backend windows --version
run_ved powershell_invalid_shell 1 'Invalid Windows shell: fish' --backend powershell --shell fish --version
run_ved powershell_invalid_drive 1 'Invalid Windows drive letter: CC' --backend powershell --windows-drive CC --version
run_ved powershell_shell_alias 0 'ved 2.1.0' --backend powershell --shell powershell --version
run_ved powershell_shell_cmd 0 'ved 2.1.0' --backend powershell --shell cmd --version
run_ved powershell_windows_write 0 'ved 2.1.0' --backend powershell --windows-write --version
run_ved help_powershell 0 'Mount a Windows partition and open pwsh or cmd' --help
run_ved help_windows_ro 0 '--windows-ro' --help
run_ved zero_ram 1 'Invalid format. Use, for example: 8G, 16G or 8192M.' --ram 0M --version
run_ved efi_loader_traversal 1 'Invalid EFI loader path: ../etc/shadow' --efi-loader ../etc/shadow --version

if run_directory_isolation; then
    pass 'run directory isolation'
else
    fail 'run directory isolation'
fi

if run_windows_helpers; then
    pass 'windows backend helpers'
else
    fail 'windows backend helpers'
fi

if run_powershell_hint; then
    pass 'powershell install hint'
else
    fail 'powershell install hint'
fi

if run_locale_messages; then
    pass 'backend locale messages'
else
    fail 'backend locale messages'
fi

if run_cli_parsing; then
    pass 'CLI option normalization'
else
    fail 'CLI option normalization'
fi

if ((failed)); then
    exit 1
fi

printf '%s CLI regression tests passed.\n' "$passed"
