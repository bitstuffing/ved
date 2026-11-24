#!/usr/bin/env bash
# Non-privileged CLI regression tests. These must never mount devices or invoke sudo.
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
VED="$PROJECT_ROOT/ved"
TMPDIR_TEST="$(mktemp -d)"
if [[ "${VED_TEST_KEEP_TMP:-0}" == "1" ]]; then
    printf 'Keeping test temp directory: %s\n' "$TMPDIR_TEST" >&2
else
    trap 'rm -rf -- "$TMPDIR_TEST"' EXIT
fi

passed=0
failed=0
skipped=0

# VED_TEST_FILTER is a substring filter, e.g.
#   VED_TEST_FILTER=docker bash tests/cli_test.sh
should_run() {
    local name="$1"
    [[ -z "${VED_TEST_FILTER:-}" || "$name" == *"$VED_TEST_FILTER"* ]]
}

pass() {
    printf 'ok - %s\n' "$1"
    ((passed += 1))
}

skip() {
    printf 'skip - %s\n' "$1"
    ((skipped += 1))
}

run_case() {
    local name="$1"
    local fn="$2"
    shift 2

    should_run "$name" || {
        skip "$name"
        return 0
    }
    if "$fn" "$@"; then
        pass "$name"
    else
        fail "$name"
    fi
}

fail() {
    printf 'not ok - %s\n' "$1" >&2
    failed=1
}

run_directory_isolation() (
    set -e
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
    set -e
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

    # An empty hiberfil.sys is just an allocation marker; it exists on cleanly
    # shut down systems with hibernation enabled and must not block writes.
    : >"$fake_win/hiberfil.sys"
    if powershell_is_hibernated "$fake_win"; then
        return 1
    fi
    truncate -s 1048576 "$fake_win/hiberfil.sys"
    if powershell_is_hibernated "$fake_win"; then
        return 1
    fi
    printf 'hibr' | dd of="$fake_win/hiberfil.sys" bs=1 count=4 conv=notrunc \
        status=none
    powershell_is_hibernated "$fake_win"

    # Without a probe, only the strong header check blocks RW access.
    powershell_volume_writable '/dev/fake' "$fake_win" && return 1
    : >"$fake_win/hiberfil.sys"
    powershell_volume_writable '/dev/fake' "$fake_win"

    # The probe is authoritative: a clean probe result overrides the fallback.
    printf 'hibr' | dd of="$fake_win/hiberfil.sys" bs=1 count=4 conv=notrunc \
        status=none
    ntfs-3g.probe() { return 0; }
    powershell_volume_writable '/dev/fake' "$fake_win"
    unset -f ntfs-3g.probe

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

    # Update preparation mode uses native pwsh and never starts Wine.
    VED_WINDOWS_MOUNT="$fake_win"
    VED_UPDATE_STAGE_DIR="$script_dir/updates"
    VED_UPDATE_WINDOWS_PATH=""
    VED_UPDATE_APPLY_SCRIPT="$VED_UPDATE_STAGE_DIR/apply-ved-updates.cmd"
    mkdir -p "$VED_UPDATE_STAGE_DIR"
    local helper
    helper="$(powershell_write_update_helper)"
    [[ -f "$helper" ]]
    grep -Fq 'function Show-VedUpdateHelp' "$helper"
    grep -Fq 'function Get-VedWindowsBuild' "$helper"
    grep -Fq 'function Save-VedUpdatePackage' "$helper"
    grep -Fq 'function Write-VedApplyScript' "$helper"
    dry_output="$(powershell_run_update "$profile" "$helper" "")"
    [[ "$dry_output" == *"VED_WINDOWS_MOUNT=$fake_win"* ]]
    [[ "$dry_output" == *"VED_UPDATE_STAGE_DIR=$VED_UPDATE_STAGE_DIR"* ]]
    [[ "$dry_output" == *"-File $script_dir/ved-update-shell.ps1"* ]]
    grep -Fq 'Show-VedUpdateHelp' "$script_dir/ved-update-shell.ps1"
    [[ "$dry_output" != *"wine"* ]]

    HTTPS_PROXY="http://proxy.example:3128"
    dry_output="$(powershell_run_update "$profile" "$helper" "")"
    [[ "$dry_output" == *"HTTPS_PROXY=http://proxy.example:3128"* ]]
    unset HTTPS_PROXY
)

run_windows_update_auto_helpers() (
    set -e
    # shellcheck source=../lib/core.sh
    source "$PROJECT_ROOT/lib/core.sh"
    # shellcheck source=../lib/disks.sh
    source "$PROJECT_ROOT/lib/disks.sh"
    # shellcheck source=../lib/backends/powershell.sh
    source "$PROJECT_ROOT/lib/backends/powershell.sh"

    t() {
        case "$1" in
            windows_update_creating_boot_entry)
                printf 'creating Windows boot entry' ;;
            windows_update_boot_entry_created)
                printf 'created Windows boot entry %s' "$2" ;;
            *) printf '%s' "$1" ;;
        esac
    }

    expect_equal() {
        [[ "$1" == "$2" ]] || {
            printf 'expected %q, got %q\n' "$2" "$1" >&2
            return 1
        }
    }

    expect_contains() {
        [[ "$1" == *"$2"* ]] || {
            printf 'output does not contain %q\n' "$2" >&2
            return 1
        }
    }

    expect_file_contains() {
        grep -Fq -- "$1" "$2" || {
            printf '%s does not contain %s\n' "$2" "$1" >&2
            return 1
        }
    }

    local root="$TMPDIR_TEST/update-auto-win"
    local stage="$TMPDIR_TEST/update-auto-stage"
    local scripts="$root/Windows/System32/GroupPolicy/Machine/Scripts/scripts.ini"
    mkdir -p "$root/VEDUpdates" "$stage" "$root/Windows/System32/GroupPolicy/Machine/Scripts/Startup"
    VED_WINDOWS_MOUNT="$root"
    VED_UPDATE_STAGE_DIR="$stage"
    VED_UPDATE_WINDOWS_PATH='C:\VEDUpdates'
    VED_ROOT="$PROJECT_ROOT"
    VED_DRY_RUN=1

    printf 'VED_UPDATE_KB=KB5132061\n' >"$stage/plan.env"
    expect_equal "$(powershell_plan_value VED_UPDATE_KB "$stage/plan.env")" KB5132061

    printf 'SUCCESS KB5132061 10.0.26100.9974\n' >"$root/VEDUpdates/ved-update-status.txt"
    local status_output
    status_output="$(powershell_show_update_status)"
    expect_contains "$status_output" 'SUCCESS KB5132061'

    local boot_next_line='BootNext: 0003'
    local boot_entry_line='Boot0002* Windows Boot Manager'
    local verbose_windows_line='Boot0002* Mi Windows HD(1,GPT,bbbb)/File(\\EFI\\Microsoft\\Boot\\bootmgfw.efi)'
    efibootmgr() {
        if [[ "${1:-}" == "-v" ]]; then
            # A renamed entry must still be found through bootmgfw.efi.
            cat <<EOF
BootCurrent: 0001
BootOrder: 0002,0001
Boot0001* Linux HD(1,GPT,aaaa)/File(\\EFI\\linux\\grubx64.efi)
$verbose_windows_line
Boot0003* Another OS HD(1,GPT,cccc)/File(\\EFI\\other\\boot.efi)
EOF
        elif [[ "${1:-}" == "-c" ]]; then
            printf '%s\n' "$*" >"$TMPDIR_TEST/efibootmgr-create.log"
            printf 'Boot000A* Windows Boot Manager (VED)\nBootOrder: 0002,0001\n'
        elif [[ "${1:-}" == "-B" ]]; then
            printf '%s\n' "$*" >"$TMPDIR_TEST/efibootmgr-delete.log"
        elif (($# == 0)); then
            cat <<EOF
BootCurrent: 0001
$boot_next_line
BootOrder: 0002,0001
Boot0001* Linux
$boot_entry_line
Boot0003* Another OS
EOF
        else
            printf 'efibootmgr %s\n' "$*"
        fi
    }
    expect_equal "$(powershell_windows_boot_entry)" 0002
    expect_equal "$(powershell_boot_next_value)" 0003

    printf '[General]\r\nVersion=7\r\n' \
        >"$root/Windows/System32/GroupPolicy/gpt.ini"
    printf '[Startup]\r\n101CmdLine=C:\\Windows\\System32\\GroupPolicy\\Machine\\Scripts\\Startup\\ved-auto-update.cmd\r\n101Parameters=\r\n' >"$scripts"
    powershell_write_auto_apply KB5132061 10.0.26100.9974 \
        'windows11.0-kb5132061-x64_test.msu windows11.0-kb5043080-x64_test.msu'
    expect_file_contains 'windows11.0-kb5132061-x64_test.msu' "$stage/ved-auto-apply.ps1"
    expect_file_contains 'windows11.0-kb5043080-x64_test.msu' "$stage/ved-auto-apply.ps1"
    expect_file_contains 'Version=8' "$root/Windows/System32/GroupPolicy/gpt.ini"
    expect_file_contains '100CmdLine=C:\Windows\System32\GroupPolicy\Machine\Scripts\Startup\ved-auto-update.cmd' "$scripts"
    if grep -Fq '101CmdLine=' "$scripts"; then
        printf 'stale startup entry was not removed\n' >&2
        return 1
    fi
    expect_file_contains '$dism /Online /Add-Package' "$stage/ved-auto-apply.ps1"
    expect_file_contains 'Remove-VedStartupEntry' "$stage/ved-auto-apply.ps1"
    expect_file_contains 'shutdown.exe' "$stage/ved-auto-apply.ps1"
    expect_file_contains '/r /t 20' "$stage/ved-auto-apply.ps1"

    VED_DRY_RUN=0
    powershell_write_auto_apply KB5132061 10.0.26100.9974 \
        'windows11.0-kb5132061-x64_test.msu' shutdown
    VED_DRY_RUN=1
    expect_file_contains '/s /t 20' "$stage/ved-auto-apply.ps1"

    powershell_validate_auto_plan KB5132061 10.0.26100.9974 \
        'windows11.0-kb5132061-x64_test.msu'
    powershell_validate_auto_plan 'KB5132061,KB5132060' 10.0.26100.9974 \
        'windows11.0-kb5132061-x64_test.msu'
    VED_DRY_RUN=0
    powershell_remove_windows_startup
    VED_DRY_RUN=1
    [[ ! -e "$root/Windows/System32/GroupPolicy/Machine/Scripts/Startup/ved-auto-update.cmd" ]]
    if grep -Fq '100CmdLine=' "$scripts"; then
        printf 'rollback did not remove the startup entry\n' >&2
        return 1
    fi

    boot_next_line=''
    local auto_output
    auto_output="$(powershell_update_auto)"
    expect_contains "$auto_output" 'lib/windows_update.sh'
    expect_contains "$auto_output" '--plan-only'
    expect_contains "$auto_output" 'efibootmgr -o 0001,0002'
    expect_contains "$auto_output" 'efibootmgr -n 0002'
    expect_contains "$auto_output" 'systemctl reboot'

    # With no Windows boot entry, VED creates one from the selected disk's ESP.
    local esp="$TMPDIR_TEST/windows-esp"
    mkdir -p "$esp/EFI/Microsoft/Boot"
    : >"$esp/EFI/Microsoft/Boot/bootmgfw.efi"
    lsblk() {
        case "$*" in
            *NAME,FSTYPE,PARTTYPE*)
                printf '/dev/fake0p1 vfat c12a7328-f81f-11d2-ba4b-00a0c93ec93b\n'
                ;;
            *PKNAME,PARTN*) printf '/dev/fake0 1\n' ;;
        esac
    }
    findmnt() { printf '%s\n' "$esp"; }
    systemctl() { return 0; }
    expect_equal "$(powershell_windows_bootloader /dev/fake0)" \
        '/dev/fake0p1|\EFI\Microsoft\Boot\bootmgfw.efi' || return 1

    boot_entry_line=''
    verbose_windows_line=''
    VED_UPDATE_BOOT_ENTRY=''
    VED_CREATE_WIN_BOOT_ENTRY=0
    VED_CREATED_WIN_BOOT_ENTRY=''
    VED_DRY_RUN=0
    VED_DISK='/dev/fake0'
    rm -f "$TMPDIR_TEST/efibootmgr-create.log" "$TMPDIR_TEST/efibootmgr-delete.log"
    powershell_ensure_boot_entry
    expect_equal "$VED_UPDATE_BOOT_ENTRY" 000A || return 1
    expect_equal "$VED_CREATE_WIN_BOOT_ENTRY" 1 || return 1
    expect_file_contains '-d /dev/fake0 -p 1' \
        "$TMPDIR_TEST/efibootmgr-create.log" || return 1
    expect_file_contains 'bootmgfw.efi' \
        "$TMPDIR_TEST/efibootmgr-create.log" || return 1
    powershell_rollback_auto
    expect_file_contains '-B -b 000A' \
        "$TMPDIR_TEST/efibootmgr-delete.log" || return 1
    expect_equal "$VED_CREATE_WIN_BOOT_ENTRY" 0 || return 1
    expect_equal "$VED_CREATED_WIN_BOOT_ENTRY" '' || return 1
)

run_windows_update_bash_helper() (
    set -e
    # shellcheck source=../lib/windows_update.sh
    source "$PROJECT_ROOT/lib/windows_update.sh"

    expect_equal() {
        [[ "$1" == "$2" ]] || {
            printf 'expected %q, got %q\n' "$2" "$1" >&2
            return 1
        }
    }

    expect_contains() {
        [[ "$1" == *"$2"* ]] || {
            printf 'output does not contain %q\n' "$2" >&2
            return 1
        }
    }

    expect_file_contains() {
        grep -Fq -- "$1" "$2" || {
            printf '%s does not contain %s\n' "$2" "$1" >&2
            return 1
        }
    }

    local fixture="$TMPDIR_TEST/update-bash-helper"
    mkdir -p "$fixture/stage" "$fixture/win/Windows/servicing/Packages"
    local rows="$fixture/rows.tsv"

    expect_equal "$(windows_update_parse_build 26100)" '10.0.26100.0'
    expect_equal "$(windows_update_parse_build 26100.7840)" '10.0.26100.7840'
    expect_equal "$(windows_update_parse_build 26100.9711.1.30)" \
        '10.0.26100.9711'
    expect_equal "$(windows_update_product 10.0.26100.7840)" 'Windows 11'
    expect_equal "$(windows_update_product 26100.9711.1.30)" 'Windows 11'
    expect_equal "$(windows_update_product 10.0.19045.3803)" 'Windows 10'
    expect_equal "$(windows_update_display_version 26100)" '24H2'
    windows_update_version_ge 10.0.26100.9974 10.0.26100.7840
    windows_update_version_ge 10.0.26100.7840 10.0.26100.7840
    if windows_update_version_ge 10.0.26100.7840 10.0.26100.9974; then
        return 1
    fi
    expect_equal "$(windows_update_urlencode 'KB5132061, KB list')" \
        'KB5132061%2C+KB+list'

    # A synthetic PE image exercises the byte-level version parser without
    # needing a real Windows installation.
    local pe="$fixture/ntoskrnl.exe"
    {
        printf 'MZ'
        dd if=/dev/zero bs=1 count=58 status=none
        printf '\x80\x00\x00\x00'
        dd if=/dev/zero bs=1 count=64 status=none
        printf 'PE\x00\x00\x64\x86'
        dd if=/dev/zero bs=1 count=122 status=none
        printf '\xbd\x04\xef\xfe\x00\x00\x00\x00\x00\x00\x0a\x00\xa0\x1e\xf4\x65\x00\x00\x0a\x00\xa0\x1e\xf4\x65'
        dd if=/dev/zero bs=1 count=64 status=none
    } >"$pe"
    windows_update_pe_version "$pe"
    expect_equal "$WU_PE_VERSION" '10.0.26100.7840'
    expect_equal "$WU_PE_ARCH" 'x64'

    : >"$fixture/win/Windows/servicing/Packages/Package_for_RollupFix~31bf3856ad364e35~amd64~~10.0.26100.7840.mum"
    expect_equal "$(windows_update_version_from_packages "$fixture/win")" \
        '10.0.26100.7840'
    mkdir -p "$fixture/mum/Windows/servicing/Packages"
    : >"$fixture/mum/Windows/servicing/Packages/Package_for_RollupFix~31bf3856ad364e35~amd64~~26100.9711.1.30.mum"
    expect_equal "$(windows_update_version_from_packages "$fixture/mum")" \
        '10.0.26100.9711'
    windows_update_offline_state "$fixture/mum"
    expect_equal "$WU_CURRENT_VERSION" '10.0.26100.9711'
    expect_equal "$WU_PRODUCT" 'Windows 11'
    windows_update_offline_state "$fixture/win" '26200.9974' 'x86'
    expect_equal "$WU_CURRENT_VERSION" '10.0.26200.9974'
    expect_equal "$WU_ARCH" 'x86'
    expect_equal "$WU_PRODUCT" 'Windows 11'

    # Catalog rows: English/Italian titles, wrong architecture and wrong build
    # family must all be handled without a locale-specific parser.
    cat >"$fixture/search.html" <<'HTML'
<table id="ctl00_catalogBody_updateMatches">
<tr id="11111111-1111-1111-1111-111111111111_R0">
<td></td><td>2026-11 Cumulative Update for Windows 11, version 24H2 for x64-based Systems (KB5132061) (26100.9974)</td><td>Windows 11</td><td>Security Updates</td><td>11/1/2026</td><td>n/a</td><td>1 MB</td><td><input /></td>
</tr>
<tr id="22222222-2222-2222-2222-222222222222_R1">
<td></td><td>2026-11 Aggiornamento cumulativo per Windows 11, version 24H2 per sistemi basati su arm64 (KB5132061) (26100.9974)</td><td>Windows 11</td><td>Security Updates</td><td>11/1/2026</td><td>n/a</td><td>1 MB</td><td><input /></td>
</tr>
<tr id="33333333-3333-3333-3333-333333333333_R2">
<td></td><td>2026-11 Cumulative Update for Windows 11, version 25H2 for x64-based Systems (KB5132061) (26200.9974)</td><td>Windows 11</td><td>Security Updates</td><td>11/1/2026</td><td>n/a</td><td>1 MB</td><td><input /></td>
</tr>
<tr id="44444444-4444-4444-4444-444444444444_R3">
<td></td><td>2026-11 Cumulative Update for Windows 11, version 24H2 for x64-based Systems (KB5132060) (26100.9974)</td><td>Windows 11</td><td>Security Updates</td><td>11/1/2026</td><td>n/a</td><td>1 MB</td><td><input /></td>
</tr>
</table>
HTML
    windows_update_parse_search_rows <"$fixture/search.html" >"$rows"
    expect_equal "$(wc -l <"$rows" | tr -d ' ')" '4'

    WU_ARCH='x64'
    WU_PRODUCT='Windows 11'
    WU_CURRENT_VERSION='10.0.26100.7840'
    local candidates
    mapfile -t candidates < <(
        windows_update_filter_rows "$rows" ''
    )
    expect_equal "${#candidates[@]}" '2'
    expect_contains "${candidates[0]}" '11111111-1111-1111-1111-111111111111'
    mapfile -t candidates < <(
        windows_update_filter_rows "$rows" 'KB5132060'
    )
    expect_equal "${#candidates[@]}" '1'
    expect_contains "${candidates[0]}" '44444444-4444-4444-4444-444444444444'

    # Only Microsoft-hosted MSU/CAB files may be staged.
    windows_update_http_post() {
        printf '%s\n' \
            "downloadInformation[0].files[0].url = 'https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/a/public/windows11.0-kb5043080-x64_a.msu';" \
            "downloadInformation[0].files[1].url = 'https://download.windowsupdate.com/d/msdownload/update/software/secu/2026/11/windows11.0-kb5132061-x64_b.msu';" \
            "downloadInformation[0].files[2].url = 'https://evil.example.com/pkg.msu';"
    }
    local urls
    urls="$(windows_update_download_urls '11111111-1111-1111-1111-111111111111')"
    expect_contains "$urls" 'windows11.0-kb5043080-x64_a.msu'
    expect_contains "$urls" 'windows11.0-kb5132061-x64_b.msu'
    if [[ "$urls" == *'evil.example.com'* ]]; then
        return 1
    fi

    WU_PACKAGE_NAMES='windows11.0-kb5043080-x64_a.msu windows11.0-kb5132061-x64_b.msu'
    WU_PACKAGE_URLS=$'https://download.windowsupdate.com/a.msu\nhttps://download.windowsupdate.com/b.msu'
    windows_update_write_plan "$fixture/stage" '10.0.26100.7840' \
        '10.0.26100.9974' 'KB5132061' 'test query'
    expect_file_contains 'VED_UPDATE_PACKAGE_COUNT=2' \
        "$fixture/stage/ved-update-plan.env"
    expect_file_contains 'windows11.0-kb5132061-x64_b.msu' \
        "$fixture/stage/ved-update-plan.env"
    expect_file_contains '"kb": "KB5132061"' "$fixture/stage/ved-update-plan.json"
    expect_file_contains '"name":"windows11.0-kb5043080-x64_a.msu"' \
        "$fixture/stage/ved-update-plan.json"
)

run_windows_update_vm_helpers() (
    set -e
    # shellcheck source=../lib/core.sh
    source "$PROJECT_ROOT/lib/core.sh"
    # shellcheck source=../lib/disks.sh
    source "$PROJECT_ROOT/lib/disks.sh"
    # shellcheck source=../lib/backends/powershell.sh
    source "$PROJECT_ROOT/lib/backends/powershell.sh"
    # shellcheck source=../lib/backends/qemu.sh
    source "$PROJECT_ROOT/lib/backends/qemu.sh"
    # shellcheck source=../lib/windows_update_vm.sh
    source "$PROJECT_ROOT/lib/windows_update_vm.sh"

    t() { printf '%s' "$1"; }
    info() { :; }
    die() {
        printf 'die: %s\n' "$*" >&2
        return 1
    }
    have() { return 0; }
    mount() { return 0; }
    sync() { return 0; }
    mkfs.vfat() { return 0; }
    umount_path() { :; }
    cleanup_add_dir() { :; }
    cleanup_add_file() { :; }
    cleanup_add_mount() { :; }
    du() { printf '1\t%s\n' "${2:-/}"; }

    expect_equal() {
        [[ "$1" == "$2" ]] || {
            printf 'expected %q, got %q\n' "$2" "$1" >&2
            return 1
        }
    }
    expect_contains() {
        [[ "$1" == *"$2"* ]] || {
            printf 'output does not contain %q\n' "$2" >&2
            return 1
        }
    }
    expect_file_contains() {
        grep -Fq -- "$1" "$2" || {
            printf '%s does not contain %s\n' "$2" "$1" >&2
            return 1
        }
    }

    local fixture="$TMPDIR_TEST/update-vm"
    mkdir -p "$fixture/esp/EFI/Microsoft/Boot" "$fixture/stage" \
        "$fixture/vm/ved-vm-esp-copy"
    : >"$fixture/esp/EFI/Microsoft/Boot/bootmgfw.efi"

    findmnt() { printf '%s\n' "$fixture/esp"; }
    lsblk() {
        case "$*" in
            *PKNAME*) printf 'fake0\n' ;;
            *NAME*) printf '/dev/fake0\n' ;;
            *) printf '1048576 3145728\n' ;;
        esac
    }

    expect_equal "$(powershell_vm_partition_range /dev/fake0p4)" \
        '1048576 3145728' || return 1

    VED_VM_DIR="$fixture/vm"
    local esp_image
    esp_image="$(powershell_vm_esp_image '\EFI\Microsoft\Boot\bootmgfw.efi' x86_64)" ||
        return 1
    [[ -f "$esp_image" ]] || return 1
    [[ -f "$fixture/vm/ved-vm-esp-copy/EFI/Boot/BootX64.efi" ]] || return 1

    local overlay="$fixture/overlay.qcow2" map="$fixture/map.txt"
    local map_src="$fixture/map-src.txt" ranges="$fixture/ranges.txt" rows
    : >"$overlay"
    VM_TEST_MAP="$map_src"
    qemu-img() {
        [[ "${1:-}" == "map" ]] && cat "$VM_TEST_MAP"
    }
    cat >"$map_src" <<EOF
Offset          Length          Mapped to       File
0               0x100000        0               $fixture/base.raw
0x100000        0x10000         0x50000         $overlay
0x200000        0x10000         0x80000         $fixture/base.raw
0x300000        0x10000         0x90000         $overlay
EOF
    rows="$(powershell_vm_changed_ranges "$overlay" "$map" "$ranges" \
        1048576 3145728)" || return 1
    expect_equal "$rows" 2 || return 1
    expect_file_contains '1048576 65536 327680' "$ranges" || return 1
    expect_file_contains '3145728 65536 589824' "$ranges" || return 1
    if grep -Fq "$fixture/base.raw" "$ranges"; then
        printf 'backing-file ranges were merged\n' >&2
        return 1
    fi

    local disk="$fixture/disk.raw" original="$fixture/original.raw"
    local merge_ranges="$fixture/merge-ranges.txt" backup="$fixture/backup.img"
    dd if=/dev/zero bs=1024 count=64 2>/dev/null | tr '\0' 'A' >"$disk"
    cp -f "$disk" "$original"
    dd if=/dev/zero bs=1024 count=64 2>/dev/null | tr '\0' 'B' >"$overlay"
    printf '0 65536 0\n' >"$merge_ranges"
    : >"$backup"
    VED_DISK="$disk"
    powershell_vm_merge_overlay "$overlay" "$backup" "$merge_ranges" || return 1
    cmp -s "$disk" "$overlay" || return 1
    powershell_vm_restore_backup "$backup" "$merge_ranges" || return 1
    cmp -s "$disk" "$original" || return 1

    VED_ROOT="$PROJECT_ROOT"
    VED_VM_DIR="$fixture/vm"
    VED_UPDATE_STAGE_DIR="$fixture/stage"
    VED_WINDOWS_MOUNT="$fixture/win"
    VED_UPDATE_KB=""
    VED_DISK='/dev/fake0'
    VED_ARCH='x86_64'
    VED_DRY_RUN=1
    print_command() {
        printf '%s ' "$@"
        printf '\n'
    }
    local dry_output
    dry_output="$(powershell_update_vm)" || return 1
    expect_contains "$dry_output" '--plan-only' || return 1
    expect_contains "$dry_output" 'qemu-img create -f qcow2 -b /dev/fake0' || return 1
    if [[ "$dry_output" == *'systemctl reboot'* ||
          "$dry_output" == *'efibootmgr'* ]]; then
        printf 'VM dry run must not change host firmware\n' >&2
        return 1
    fi

    display_build_args() { return 0; }
    qemu_machine() { printf 'pc'; }
    qemu_escape() { printf '%s' "$1"; }
    qemu_disk_serial() { printf 'vedserial'; }
    spice_agent_args() { :; }
    VED_ACCEL_ACTUAL='kvm'
    VED_CPUS='2'
    VED_RAM='4G'
    VED_STORAGE_OPTS=()
    VED_OVMF_CODE='/usr/share/OVMF/OVMF_CODE.fd'
    VED_OVMF_CODE_FORMAT='raw'
    VED_OVMF_VARS_TEMP='/tmp/ved-vars.fd'
    VED_OVMF_VARS_FORMAT='raw'
    VED_IMAGE="$overlay"
    VED_IMAGE_FORMAT='qcow2'
    VED_ESP_IMAGE="$esp_image"
    VED_GUEST_OS='windows'
    VED_ARCH='x86_64'
    VED_NETWORK='none'
    VED_BOOT_MENU=1
    VED_DISPLAY_ARGS=()
    VED_AUDIO_ARGS=()
    VED_USB_ARGS=()
    VED_TPM_ARGS=()
    qemu_build_args spice node || return 1
    local qemu_args=" ${VED_QEMU_ARGS[*]} "
    expect_contains "$qemu_args" " file=$esp_image,format=raw,if=none,id=ved-esp,readonly=on " || return 1
    expect_contains "$qemu_args" ' virtio-blk-pci,drive=ved-esp,bootindex=0 ' || return 1
    expect_contains "$qemu_args" " file=$overlay,format=qcow2,if=none,id=ved-disk,cache=writeback,aio=threads " || return 1
    expect_contains "$qemu_args" ' nvme,drive=ved-disk,serial=vedserial,bootindex=1 ' || return 1
)

run_shell_auto_menu() (
    set -e
    # shellcheck source=../lib/core.sh
    source "$PROJECT_ROOT/lib/core.sh"
    # shellcheck source=../lib/ui.sh
    source "$PROJECT_ROOT/lib/ui.sh"

    t() { printf '%s' "$1"; }
    info() { :; }
    ask() { printf '4'; }

    VED_SHELL="pwsh"
    VED_UPDATE_AUTO=0
    VED_WINDOWS_WRITE=0
    VED_WINDOWS_WRITE_SET=0
    select_shell
    [[ "$VED_SHELL" == "update" ]]
    [[ "$VED_UPDATE_AUTO" -eq 1 ]]
    [[ "$VED_WINDOWS_WRITE" -eq 1 ]]
    [[ "$VED_WINDOWS_WRITE_SET" -eq 1 ]]
)

run_shell_auto_vm_menu() (
    set -e
    # shellcheck source=../lib/core.sh
    source "$PROJECT_ROOT/lib/core.sh"
    # shellcheck source=../lib/ui.sh
    source "$PROJECT_ROOT/lib/ui.sh"

    t() { printf '%s' "$1"; }
    info() { :; }
    ask() { printf '5'; }

    VED_SHELL="pwsh"
    VED_UPDATE_AUTO=0
    VED_UPDATE_VM=0
    VED_WINDOWS_WRITE=0
    VED_WINDOWS_WRITE_SET=0
    select_shell
    [[ "$VED_SHELL" == "update" ]]
    [[ "$VED_UPDATE_AUTO" -eq 1 ]]
    [[ "$VED_UPDATE_VM" -eq 1 ]]
    [[ "$VED_WINDOWS_WRITE" -eq 1 ]]
    [[ "$VED_WINDOWS_WRITE_SET" -eq 1 ]]
)

run_powershell_hint() (
    set -e
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
    set -e
    # shellcheck source=../lib/i18n.sh
    source "$PROJECT_ROOT/lib/i18n.sh"
    VED_ROOT="$PROJECT_ROOT"

    check_keys() {
        local key
        for key in backend_powershell backend_docker shell_user_invalid windows_temp_failed \
                   shell_update powershell_update_shell powershell_update_command \
                   powershell_update_stage_ro powershell_update_stage_failed \
                   windows_update_kb_invalid windows_update_powershell_only \
                   windows_update_auto_conflict windows_update_auto_shell_conflict \
                   windows_update_auto_requires_write windows_update_auto_warning \
                   windows_update_efibootmgr_missing windows_update_boot_entry_missing \
                   windows_update_creating_boot_entry windows_update_boot_entry_created \
                   windows_update_boot_entry_create_failed windows_update_boot_entry_dry_run \
                   windows_update_auto_confirm windows_update_found \
                   windows_update_discovery_failed windows_update_up_to_date \
                   windows_update_boot_restore_ready windows_update_boot_restore_failed \
                   windows_update_status_title windows_update_no_status \
                   memlock_raise_failed guest_fips_mask_failed \
                   login1_stub_failed docker_chroot_warning docker_skopeo_missing \
                   docker_image_prompt docker_platform_mismatch docker_layer_apply \
                   docker_workdir_missing docker_home_prepared; do
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
    set -e
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

    parse_cli --backend powershell --shell update
    [[ "$VED_SHELL" == "update" ]]
    parse_cli --backend powershell --shell windows-update
    [[ "$VED_SHELL" == "update" ]]
    parse_cli --backend powershell --shell wu
    [[ "$VED_SHELL" == "update" ]]

    VED_UPDATE_AUTO=0
    VED_UPDATE_KB=""
    VED_UPDATE_SHOW_STATUS=0
    VED_WINDOWS_WRITE_SET=0
    VED_WINDOWS_WRITE=0
    parse_cli --backend powershell --auto
    [[ "$VED_SHELL" == "update" ]]
    [[ "$VED_UPDATE_AUTO" -eq 1 ]]
    [[ "$VED_WINDOWS_WRITE" -eq 1 ]]

    VED_UPDATE_AUTO=0
    VED_UPDATE_SHOW_STATUS=0
    parse_cli --backend powershell --update-status
    [[ "$VED_UPDATE_SHOW_STATUS" -eq 1 ]]
    [[ "$VED_WINDOWS_WRITE" -eq 0 ]]

    VED_UPDATE_SHOW_STATUS=0
    parse_cli --backend powershell --auto --kb KB5132061,KB5132060
    [[ "$VED_UPDATE_KB" == "KB5132061,KB5132060" ]]

    VED_UPDATE_AUTO=0
    VED_UPDATE_KB=""
    parse_cli --backend powershell --kb KB5132061
    [[ "$VED_UPDATE_AUTO" -eq 1 ]]
    [[ "$VED_SHELL" == "update" ]]

    VED_UPDATE_AUTO=0
    VED_UPDATE_KB=""
    VED_UPDATE_SHOW_STATUS=0
    VED_WINDOWS_WRITE_SET=0
    VED_WINDOWS_WRITE=0
    parse_cli --backend docker --image alpine:latest --docker-storage "$TMPDIR_TEST/oci" \
        --docker-reset --docker-list --arch aarch64
    [[ "$VED_BACKEND" == "docker" ]]
    [[ "$VED_IMAGE" == "alpine:latest" ]]
    [[ "$VED_DOCKER_STORAGE" == "$TMPDIR_TEST/oci" ]]
    [[ "$VED_DOCKER_RESET" -eq 1 ]]
    [[ "$VED_DOCKER_LIST" -eq 1 ]]
    [[ "$VED_ARCH" == "aarch64" ]]
)

run_session_helpers() (
    set -e
    # shellcheck source=../lib/core.sh
    source "$PROJECT_ROOT/lib/core.sh"
    # shellcheck source=../lib/session.sh
    source "$PROJECT_ROOT/lib/session.sh"

    t() {
        local key="$1"
        shift
        printf '%s' "$key"
    }

    # select_desktop_session() prompts when stdin is a TTY; this unit-style
    # helper loads session.sh without the CLI, so provide the missing input.
    ask() {
        printf '%s\n' "${VED_TEST_ASK_ANSWER:-3}"
    }

    local root="$TMPDIR_TEST/session-root"
    mkdir -p "$root/usr/share/wayland-sessions" \
        "$root/usr/share/xsessions" \
        "$root/usr/bin" \
        "$root/usr/libexec"

    cat >"$root/usr/share/wayland-sessions/gnome.desktop" <<'EOF'
[Desktop Entry]
Name=GNOME
Exec=gnome-session
TryExec=gnome-session
DesktopNames=GNOME
EOF
    cat >"$root/usr/share/xsessions/gnome-xorg.desktop" <<'EOF'
[Desktop Entry]
Name=GNOME on Xorg
Exec=gnome-session --session=gnome-xorg %f
TryExec=gnome-session
EOF
    cat >"$root/usr/share/xsessions/xfce.desktop" <<'EOF'
[Desktop Entry]
Name=Xfce
Exec=startxfce4
DesktopNames=XFCE
EOF
    cat >"$root/usr/share/xsessions/hidden.desktop" <<'EOF'
[Desktop Entry]
Name=Hidden
Exec=hidden-session
Hidden=true
EOF
    : >"$root/usr/bin/gnome-session"
    : >"$root/usr/bin/dbus-run-session"
    : >"$root/usr/bin/gnome-shell"
    : >"$root/usr/libexec/mutter-devkit"
    chmod +x "$root/usr/bin/gnome-session" \
        "$root/usr/bin/dbus-run-session" \
        "$root/usr/bin/gnome-shell" \
        "$root/usr/libexec/mutter-devkit"

    local -a sessions=()
    mapfile -t sessions < <(detect_desktop_sessions "$root")
    [[ ${#sessions[@]} -eq 3 ]]
    [[ "${sessions[0]}" == *'|wayland' ]]
    [[ "${sessions[1]}" == *'gnome-session --session=gnome-xorg|'* ]]
    [[ "${sessions[2]}" == 'Xfce|startxfce4|xsessions/xfce.desktop|x11' ]]

    # A GNOME 49 guest must never offer its leftover X11 session.
    VED_SESSION=desktop
    VED_COMMAND=""
    VED_GUI_TARGET=nested
    VED_GUEST_NO_X11=1
    VED_GUEST_SESSION_TYPE=""
    select_desktop_session "$root"
    [[ "$VED_COMMAND" == "startxfce4" ]]
    [[ "$VED_GUEST_SESSION_TYPE" == "x11" ]]
    [[ "$VED_GUEST_SESSION_DESKTOP" == "xfce" ]]
    [[ "$VED_GUEST_CURRENT_DESKTOP" == "XFCE" ]]

    set_guest_desktop_identity 'ubuntu:GNOME'
    [[ "$VED_GUEST_SESSION_DESKTOP" == "ubuntu" ]]
    [[ "$VED_GUEST_CURRENT_DESKTOP" == "ubuntu:GNOME" ]]

    VED_BACKEND=chroot
    VED_GUEST_RUNTIME=""
    [[ "$(session_build_command "$root")" == "dbus-run-session -- startxfce4" ]]

    # An already wrapped command must not get a second session bus.
    VED_COMMAND="dbus-run-session -- startxfce4"
    [[ "$(session_build_command "$root")" == "dbus-run-session -- startxfce4" ]]

    # GNOME 49 uses the devkit path and forces the host display.
    chroot() {
        printf 'GNOME Shell 49.1\n'
    }
    VED_COMMAND=""
    VED_GUI_TARGET=nested
    session_probe_guest "$root"
    [[ "$VED_GUEST_GNOME_MAJOR" == "49" ]]
    [[ "$VED_GUEST_NO_X11" -eq 1 ]]
    [[ "$VED_GUEST_DEVKIT_OK" -eq 1 ]]
    [[ "$VED_GUI_TARGET" == "host" ]]
    [[ "$VED_COMMAND" == *'gnome-shell --devkit --wayland'* ]]
    [[ "$VED_GUEST_SESSION_TYPE" == "wayland" ]]
    [[ "$VED_GUEST_SESSION_DESKTOP" == "gnome" ]]
    [[ "$VED_GUEST_CURRENT_DESKTOP" == "GNOME" ]]

    local built
    built="$(session_build_command "$root")"
    [[ "$built" == dbus-run-session\ --\ gnome-shell\ --devkit* ]]
    [[ "$built" != *'dbus-run-session -- dbus-run-session'* ]]

    # Without devkit the broken X11 session is filtered out instead of
    # leaving the user with a black screen.
    rm -f "$root/usr/libexec/mutter-devkit"
    VED_COMMAND=""
    VED_GUI_TARGET=host
    session_probe_guest "$root"
    [[ "$VED_GUEST_NO_X11" -eq 1 ]]
    [[ -z "$VED_COMMAND" ]]
    if select_desktop_session "$root"; then
        [[ "$VED_COMMAND" != *gnome* ]]
    fi

    # Wayland sessions get a private Xwayland display number; X11 and devkit
    # sessions keep the host display.
    VED_GUI_TARGET="host"
    DISPLAY=":0"
    VED_GUEST_SESSION_TYPE="wayland"
    VED_COMMAND="startxfce4 --wayland"
    local wayland_display
    wayland_display="$(guest_display_value)"
    [[ "$wayland_display" != ":0" && "$wayland_display" == :* ]]

    VED_GUEST_SESSION_TYPE="x11"
    [[ "$(guest_display_value)" == ":0" ]]

    VED_GUEST_SESSION_TYPE="wayland"
    VED_COMMAND="gnome-shell --devkit --wayland"
    [[ "$(guest_display_value)" == ":0" ]]

    # A guest compositor must not receive the host Wayland socket name, and
    # /tmp/.X11-unix must be shared so Xwayland sees occupied display numbers.
    VED_SESSION="desktop"
    VED_COMMAND="startxfce4 --wayland"
    guest_starts_compositor || return 1
    VED_COMMAND="xterm"
    VED_GUEST_SESSION_TYPE="x11"
    if guest_starts_compositor; then
        return 1
    fi
    VED_SESSION="shell"
    VED_COMMAND="startxfce4 --wayland"
    VED_GUEST_SESSION_TYPE="wayland"
    if guest_starts_compositor; then
        return 1
    fi

    # Docker images cannot boot a whole system, so that option is not offered.
    VED_BACKEND="docker"
    VED_SESSION="auto"
    VED_SESSION_SET=0
    VED_GRAPHICAL=0
    VED_TEST_ASK_ANSWER=3
    select_session_menu >/dev/null
    [[ "$VED_SESSION" == "desktop" ]]

    VED_SESSION="auto"
    local docker_menu
    docker_menu="$(select_session_menu)"
    [[ "$docker_menu" != *session_system* ]]

    die() {
        printf '%s\n' "$*" >&2
        exit 1
    }
    VED_SESSION="auto"
    if ( VED_TEST_ASK_ANSWER=4; select_session_menu ) >/dev/null 2>&1; then
        return 1
    fi
)

run_chroot_identity_helpers() (
    set -e
    # shellcheck source=../lib/core.sh
    source "$PROJECT_ROOT/lib/core.sh"
    # shellcheck source=../lib/session.sh
    source "$PROJECT_ROOT/lib/session.sh"
    # shellcheck source=../lib/backends/chroot.sh
    source "$PROJECT_ROOT/lib/backends/chroot.sh"
    # shellcheck source=../lib/backends/nspawn.sh
    source "$PROJECT_ROOT/lib/backends/nspawn.sh"

    t() {
        local key="$1"
        printf '%s' "$key"
    }

    local root="$TMPDIR_TEST/identity-root"
    mkdir -p "$root/etc" "$root/usr/bin" "$root/bin"
    printf 'bbm-Precision-5770\n' > "$root/etc/hostname"
    printf 'root:x:0:0:root:/root:/bin/sh\n' > "$root/etc/passwd"
    : > "$root/usr/bin/env"
    : > "$root/bin/sh"
    chmod +x "$root/usr/bin/env" "$root/bin/sh"

    [[ "$(guest_hostname "$root")" == "bbm-Precision-5770" ]]

    VED_GRAPHICAL=1
    VED_DRY_RUN=1
    VED_GUEST_RUNTIME="/run/user/1000"
    VED_GUI_TARGET="host"
    VED_SESSION="desktop"
    VED_GUEST_SYSTEM_BUS_ADDRESS="unix:path=/run/dbus/system_bus_socket"
    VED_GUEST_SESSION_DESKTOP="gnome"
    VED_GUEST_CURRENT_DESKTOP="ubuntu:GNOME"
    XDG_SESSION_DESKTOP="hostsession"
    XDG_CURRENT_DESKTOP="HostDesktop"
    HOSTNAME="bitbara"

    have() {
        case "$1" in
            unshare|hostname) return 0 ;;
            *) command -v "$1" >/dev/null 2>&1 ;;
        esac
    }

    local output
    output="$(chroot_run "$root" "root" "startxfce4")"
    [[ "$output" == *"unshare --uts"* ]]
    [[ "$output" == *"sh bbm-Precision-5770 guest_hostname_set_failed"* ]]
    [[ "$output" == *"HOSTNAME=bbm-Precision-5770"* ]]
    [[ "$output" == *"XDG_SESSION_DESKTOP=gnome"* ]]
    [[ "$output" == *"XDG_CURRENT_DESKTOP=ubuntu:GNOME"* ]]
    [[ "$output" == *"DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket"* ]]
    [[ "$output" != *"XDG_SESSION_DESKTOP=hostsession"* ]]
    [[ "$output" != *"XDG_CURRENT_DESKTOP=HostDesktop"* ]]
    [[ "$output" != *"HOSTNAME=bitbara"* ]]

    # Without unshare the desktop still starts; it just keeps host identity.
    have() { return 1; }
    output="$(chroot_run "$root" "root" "startxfce4")"
    [[ "$output" != *"unshare --uts"* ]]
    [[ "$output" == *"XDG_SESSION_DESKTOP=gnome"* ]]

    # nspawn gets the same guest hostname and desktop identity.
    VED_BOOT=0
    VED_DISK="/dev/nvme0n1p2"
    nspawn_build_args "$root" "root" "startxfce4"
    local joined=" ${NSPAWN_ARGS[*]} "
    [[ "$joined" == *" --hostname=bbm-Precision-5770 "* ]]
    [[ "$joined" == *" --setenv=HOSTNAME=bbm-Precision-5770 "* ]]
    [[ "$joined" == *" --setenv=XDG_SESSION_DESKTOP=gnome "* ]]
    [[ "$joined" == *" --setenv=XDG_CURRENT_DESKTOP=ubuntu:GNOME "* ]]
    [[ "$joined" != *" --setenv=XDG_CURRENT_DESKTOP=HostDesktop "* ]]
)

run_chroot_system_bus_config() (
    set -e
    # shellcheck source=../lib/core.sh
    source "$PROJECT_ROOT/lib/core.sh"
    # shellcheck source=../lib/session.sh
    source "$PROJECT_ROOT/lib/session.sh"
    # shellcheck source=../lib/backends/chroot.sh
    source "$PROJECT_ROOT/lib/backends/chroot.sh"

    t() { printf '%s' "$1"; }

    VED_GRAPHICAL=1
    VED_DRY_RUN=0
    VED_RUN_DIR="$TMPDIR_TEST/bus-run"
    mkdir -p "$VED_RUN_DIR"
    local root="$TMPDIR_TEST/bus-root"
    mkdir -p "$root"
    local binds="$TMPDIR_TEST/bus-binds"
    : > "$binds"

    chroot_bind() {
        printf '%s|%s\n' "$1" "$2" >> "$binds"
        return 0
    }
    chroot_start_system_bus() { return 0; }

    chroot_prepare_mounts "$root"
    grep -Fq "$VED_RUN_DIR/guest-dbus|$root/run/dbus" "$binds"
    ! grep -Fq '/run/dbus|' "$binds"
    grep -Fq "/dev/null|$root/etc/gcrypt/fips_enabled" "$binds"
    [[ "$VED_GUEST_SYSTEM_BUS_ADDRESS" == "unix:path=/run/dbus/system_bus_socket" ]]
)

run_fips_mask_helper() (
    set -e
    # shellcheck source=../lib/core.sh
    source "$PROJECT_ROOT/lib/core.sh"
    t() { printf '%s' "$1"; }

    local root="$TMPDIR_TEST/fips-root"
    mkdir -p "$root/etc"
    local masked
    masked="$(prepare_guest_nonfips_config "$root")"
    [[ "$masked" == "$root/etc/gcrypt/fips_enabled" ]]
    [[ -f "$masked" ]]
)

run_nspawn_graphical_hardening() (
    set -e
    # shellcheck source=../lib/core.sh
    source "$PROJECT_ROOT/lib/core.sh"
    # shellcheck source=../lib/session.sh
    source "$PROJECT_ROOT/lib/session.sh"
    # shellcheck source=../lib/backends/chroot.sh
    source "$PROJECT_ROOT/lib/backends/chroot.sh"
    # shellcheck source=../lib/backends/nspawn.sh
    source "$PROJECT_ROOT/lib/backends/nspawn.sh"

    t() { printf '%s' "$1"; }

    local root="$TMPDIR_TEST/nspawn-hardening-root"
    mkdir -p "$root/etc" "$root/usr/bin" "$root/bin"
    printf 'bbm-Precision-5770\n' > "$root/etc/hostname"
    printf 'root:x:0:0:root:/root:/bin/sh\n' > "$root/etc/passwd"
    : > "$root/usr/bin/env"
    : > "$root/bin/sh"
    chmod +x "$root/usr/bin/env" "$root/bin/sh"

    VED_GRAPHICAL=1
    VED_BOOT=0
    VED_DRY_RUN=1
    VED_DISK="/dev/nvme0n1p2"
    VED_RUN_DIR="$TMPDIR_TEST/nspawn-run"
    VED_GUEST_RUNTIME="/run/user/1000"

    prepare_guest_nonfips_config "$root" >/dev/null
    nspawn_prepare_graphical_bus "$root"
    [[ "$VED_NSPAWN_GUEST_BUS_DIR" == "$VED_RUN_DIR/nspawn-guest-dbus" ]]
    nspawn_build_args "$root" "root" 'dbus-run-session -- gnome-shell'
    local joined=" ${NSPAWN_ARGS[*]} "
    [[ "$joined" == *" --rlimit=MEMLOCK=infinity "* ]]
    [[ "$joined" == *" --bind=$VED_RUN_DIR/nspawn-guest-dbus:/run/dbus "* ]]
    [[ "$joined" == *" --bind-ro=/dev/null:/etc/gcrypt/fips_enabled "* ]]
    [[ "$joined" == *" -u LIBGCRYPT_FORCE_FIPS_MODE "* ]]
    [[ "$joined" == *" --setenv=DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/dbus/system_bus_socket "* ]]
    [[ "$joined" != *" --bind=/run/dbus "* ]]
)

run_memlock_helper() (
    set -e
    # shellcheck source=../lib/core.sh
    source "$PROJECT_ROOT/lib/core.sh"
    t() { printf '%s' "$1"; }

    local prlimit_calls=0
    prlimit() {
        ((prlimit_calls += 1))
        return 0
    }
    have() { [[ "$1" == prlimit ]]; }
    ulimit() {
        case "$1" in
            -Sl|-Hl) printf '1024' ;;
            *) return 0 ;;
        esac
    }

    VED_GRAPHICAL=0
    raise_graphical_memlock_limit
    [[ "$prlimit_calls" -eq 0 ]]

    VED_GRAPHICAL=1
    raise_graphical_memlock_limit
    [[ "$prlimit_calls" -eq 1 ]]
)

run_login1_stub_generator() (
    set -e
    command -v python3 >/dev/null 2>&1 || return 0

    local script="$TMPDIR_TEST/ved-login1-stub.py"
    awk '/^    cat > "\$stub_host" <<.PY.$/{flag=1;next}
         flag && /^PY$/{exit}
         flag' "$PROJECT_ROOT/lib/backends/chroot.sh" > "$script"

    [[ -s "$script" ]]
    python3 -m py_compile "$script"
    grep -Fq 'VED_LOGIN1_READY' "$script"
    grep -Fq 'VED_LOGIN1_MACHINE_ID' "$script"
    grep -Fq 'org.freedesktop.login1.Manager' "$script"
    grep -Fq 'org.gnome.DisplayManager.Manager' "$script"
    grep -Fq 'CanSuspend' "$script"
    grep -Fq 'RegisterSession' "$script"
)

run_docker_helpers() (
    set -e
    # shellcheck source=../lib/core.sh
    source "$PROJECT_ROOT/lib/core.sh"
    # shellcheck source=../lib/docker/registry.sh
    source "$PROJECT_ROOT/lib/docker/registry.sh"
    # shellcheck source=../lib/docker/image.sh
    source "$PROJECT_ROOT/lib/docker/image.sh"
    # shellcheck source=../lib/docker/rootfs.sh
    source "$PROJECT_ROOT/lib/docker/rootfs.sh"

    t() { printf '%s' "$1"; }
    have() { command -v "$1" >/dev/null 2>&1; }

    VED_DOCKER_STORAGE="$TMPDIR_TEST/oci-storage"
    VED_GUI_USER=""
    VED_ARCH="auto"

    [[ "$(docker_normalize_image_ref 'docker://alpine:latest')" == "alpine:latest" ]]
    [[ "$(docker_normalize_image_ref 'oci:debian:stable')" == "debian:stable" ]]
    if docker_normalize_image_ref 'bad ref'; then
        return 1
    fi

    [[ "$(docker_storage_base)" == "$TMPDIR_TEST/oci-storage" ]]
    local id image_dir root_dir
    id="$(docker_image_id 'alpine:latest')"
    [[ ${#id} -eq 16 ]]
    image_dir="$(docker_image_cache_dir 'alpine:latest')"
    root_dir="$(docker_rootfs_dir 'alpine:latest')"
    [[ "$image_dir" == "$TMPDIR_TEST/oci-storage/images/$id" ]]
    [[ "$root_dir" == "$TMPDIR_TEST/oci-storage/rootfs/$id" ]]

    mkdir -p "$image_dir"
    printf '%s\n' 'alpine:latest' >"$image_dir/reference"
    printf '%s' '{"schemaVersion":2,"config":{"digest":"sha256:aaaa"},"layers":[{"digest":"sha256:bbbb"},{"digest":"sha256:cccc"}]}' \
        >"$image_dir/manifest.json"
    [[ "$(docker_image_config_digest "$image_dir/manifest.json")" == "sha256:aaaa" ]]
    [[ "$(docker_image_layer_digests "$image_dir/manifest.json")" == $'sha256:bbbb\nsha256:cccc' ]]
    [[ "$(docker_blob_path "$image_dir" 'sha256:aaaa')" == "$image_dir/aaaa" ]]
    printf 'not a digest' >"$image_dir/aaaa"
    if docker_registry_cache_valid "$image_dir"; then
        return 1
    fi
    printf '{}' >"$image_dir/aaaa"

    mkdir -p "$TMPDIR_TEST/layer1/usr/bin" "$TMPDIR_TEST/layer1/usr/dir"
    printf 'hello\n' >"$TMPDIR_TEST/layer1/usr/bin/ved-hello"
    printf 'old\n' >"$TMPDIR_TEST/layer1/usr/old-file"
    printf 'keep\n' >"$TMPDIR_TEST/layer1/usr/dir/keep"
    printf 'drop\n' >"$TMPDIR_TEST/layer1/usr/dir/drop"
    tar -czf "$image_dir/bbbb" -C "$TMPDIR_TEST/layer1" .

    mkdir -p "$TMPDIR_TEST/layer2/usr/dir"
    : >"$TMPDIR_TEST/layer2/usr/.wh.old-file"
    : >"$TMPDIR_TEST/layer2/usr/dir/.wh..wh..opq"
    printf 'new\n' >"$TMPDIR_TEST/layer2/usr/dir/new-file"
    tar -czf "$image_dir/cccc" -C "$TMPDIR_TEST/layer2" .
    docker_registry_cache_valid "$image_dir"

    VED_DOCKER_RESET=1
    VED_DOCKER_ROOTFS=""
    local prepare_output="$TMPDIR_TEST/prepare.out"
    docker_rootfs_prepare "$image_dir" 'alpine:latest' >"$prepare_output"
    [[ -n "$VED_DOCKER_ROOTFS" ]]
    if grep -Fq "$VED_DOCKER_ROOTFS" "$prepare_output"; then
        return 1
    fi
    [[ -f "$VED_DOCKER_ROOTFS/usr/bin/ved-hello" ]]
    [[ ! -e "$VED_DOCKER_ROOTFS/usr/old-file" ]]
    [[ ! -e "$VED_DOCKER_ROOTFS/usr/dir/keep" ]]
    [[ ! -e "$VED_DOCKER_ROOTFS/usr/dir/drop" ]]
    [[ -f "$VED_DOCKER_ROOTFS/usr/dir/new-file" ]]
    [[ ! -e "$VED_DOCKER_ROOTFS/usr/.wh.old-file" ]]
    [[ -f "$VED_DOCKER_ROOTFS/.ved-docker-image" ]]
    [[ "$(cat "$VED_DOCKER_ROOTFS/etc/hostname")" == "alpine" ]]

    printf 'persist\n' >"$VED_DOCKER_ROOTFS/ved-persistent"
    VED_DOCKER_RESET=0
    : >"$prepare_output"
    docker_rootfs_prepare "$image_dir" 'alpine:latest' >"$prepare_output"
    [[ ! -s "$prepare_output" ]]
    [[ -f "$VED_DOCKER_ROOTFS/ved-persistent" ]]

    local host_arch image_arch
    host_arch="$(uname -m)"
    case "$host_arch" in
        aarch64) image_arch="arm64" ;;
        *) image_arch="amd64" ;;
    esac
    printf '{"architecture":"%s","os":"linux","config":{"Env":["FOO=bar","PATH=/usr/bin","HOME=/root"],"Entrypoint":["/bin/sh","-c"],"Cmd":["printf hi"],"WorkingDir":"/work"}}' \
        "$image_arch" >"$image_dir/aaaa"

    VED_GUEST_IMAGE_ENV=()
    docker_image_load_metadata "$image_dir" || return 1
    [[ " ${VED_GUEST_IMAGE_ENV[*]} " == *" FOO=bar "* ]]
    [[ " ${VED_GUEST_IMAGE_ENV[*]} " != *" PATH="* ]]
    [[ " ${VED_GUEST_IMAGE_ENV[*]} " != *" HOME="* ]]
    [[ "${VED_DOCKER_ENTRYPOINT[*]}" == "/bin/sh -c" ]]
    [[ "${VED_DOCKER_CMD[*]}" == "printf hi" ]]
    [[ "$VED_DOCKER_WORKDIR" == "/work" ]]
    [[ "$VED_DOCKER_ARCH" == "$image_arch" ]]
    docker_image_check_platform

    [[ "$(docker_image_default_command)" == "'/bin/sh' '-c' 'printf hi'" ]]
    [[ "$(shell_quote_posix "it's here")" == "'it'\\''s here'" ]]

    [[ "$(docker_whiteout_info 'usr/.wh.old')" == "file|usr|old" ]]
    [[ "$(docker_whiteout_info 'usr/.wh..wh..opq')" == "opq|usr|" ]]
    docker_path_is_safe 'usr/lib/file'
    mkdir -p "$VED_DOCKER_ROOTFS/usr"
    ln -sfn /tmp "$VED_DOCKER_ROOTFS/usr/link"
    docker_path_has_symlink_component "$VED_DOCKER_ROOTFS" 'usr/link'
    if docker_path_has_symlink_component "$VED_DOCKER_ROOTFS" 'usr/bin'; then
        return 1
    fi
    if docker_path_is_safe '../etc/passwd'; then
        return 1
    fi
    if docker_path_is_safe '/etc/passwd'; then
        return 1
    fi
    [[ "$(docker_tar_path './usr/lib/')" == "usr/lib" ]]

    local home_root="$TMPDIR_TEST/home-root"
    mkdir -p "$home_root/etc"
    printf '%s\n' 'dockremap:x:1000:1000::/home/dockremap:/bin/sh' \
        >"$home_root/etc/passwd"
    VED_GUEST_UID=1000
    VED_GUEST_GID=1000
    docker_ensure_guest_home "$home_root" 'dockremap'
    [[ -d "$home_root/home/dockremap/.config/xfce4/labwc" ]]
    [[ -d "$home_root/home/dockremap/Desktop" ]]
)

run_docker_backend_flow() (
    set -e
    # shellcheck source=../lib/core.sh
    source "$PROJECT_ROOT/lib/core.sh"
    # shellcheck source=../lib/docker/registry.sh
    source "$PROJECT_ROOT/lib/docker/registry.sh"
    # shellcheck source=../lib/docker/image.sh
    source "$PROJECT_ROOT/lib/docker/image.sh"
    # shellcheck source=../lib/docker/rootfs.sh
    source "$PROJECT_ROOT/lib/docker/rootfs.sh"
    # shellcheck source=../lib/backends/docker.sh
    source "$PROJECT_ROOT/lib/backends/docker.sh"

    t() { printf '%s' "$1"; }
    have() { command -v "$1" >/dev/null 2>&1; }
    die() {
        printf '%s\n' "$*" >&2
        return 1
    }
    docker_registry_require() { :; }
    docker_registry_pull() {
        mkdir -p "$2"
        printf '%s\n' 'debian:stable' >"$2/reference"
    }
    docker_image_load_metadata() {
        VED_GUEST_IMAGE_ENV=("FOO=bar")
        VED_DOCKER_WORKDIR="/work"
        VED_DOCKER_ENTRYPOINT=("/init")
        VED_DOCKER_CMD=()
    }
    docker_image_check_platform() { :; }
    docker_rootfs_prepare() {
        VED_DOCKER_ROOTFS="$TMPDIR_TEST/backend-rootfs"
        mkdir -p "$VED_DOCKER_ROOTFS/work"
    }
    select_session() { :; }
    chroot_prepare_graphical_session() { :; }
    chroot_execute_session() { :; }

    VED_BACKEND="docker"
    VED_IMAGE="docker://debian:stable"
    VED_SESSION="shell"
    VED_DOCKER_STORAGE="$TMPDIR_TEST/backend-storage"
    VED_DOCKER_LIST=0
    VED_DOCKER_PRUNE=0
    VED_DOCKER_RESET=0
    VED_DISK=""
    VED_ROOT_PARTITION=""
    VED_DOCKER_IMAGE_REF=""
    VED_GUEST_IMAGE_ENV=()
    VED_CHROOT_WORKDIR=""
    VED_COMMAND=""

    backend_docker

    [[ "$VED_DOCKER_IMAGE_REF" == "debian:stable" ]]
    [[ "$VED_CHROOT_DIR" == "$TMPDIR_TEST/backend-rootfs" ]]
    [[ "$VED_CHROOT_WORKDIR" == "/work" ]]
    [[ "${VED_GUEST_IMAGE_ENV[*]}" == "FOO=bar" ]]
    [[ "$VED_CHROOT_DISABLE_UTS" -eq 1 ]]
    # An s6 /init entrypoint must not replace an interactive shell.
    [[ -z "$VED_COMMAND" ]]

    # It is still a valid fallback for single-app sessions.
    VED_SESSION="app"
    backend_docker
    [[ "$VED_COMMAND" == *'/init'* ]]
)

run_wayland_socket_export() (
    set -e
    # shellcheck source=../lib/core.sh
    source "$PROJECT_ROOT/lib/core.sh"
    # shellcheck source=../lib/session.sh
    source "$PROJECT_ROOT/lib/session.sh"

    t() { printf '%s' "$1"; }
    have() { command -v "$1" >/dev/null 2>&1; }
    die() {
        printf '%s\n' "$*" >&2
        return 1
    }
    warn() { :; }
    info() { :; }
    cleanup_add_dir() { :; }
    install() { :; }
    mkdir() { :; }
    rm() { :; }
    gui_runtime_export_socket() {
        printf '%s\n' "$2" >>"$VED_TEST_EXPORT_LOG"
    }

    local sock="$TMPDIR_TEST/wayland-0"
    printf 'sock' >"$sock"
    VED_GRAPHICAL=1
    VED_GUEST_UID=1000
    VED_GUEST_GID=1000
    VED_GUI_RUNTIME="$TMPDIR_TEST"
    VED_GUI_TARGET="host"
    VED_SESSION="desktop"
    VED_GUEST_SESSION_TYPE="wayland"
    VED_COMMAND="startxfce4 --wayland"
    WAYLAND_DISPLAY="wayland-0"
    VED_TEST_EXPORT_LOG="$TMPDIR_TEST/export.log"

    prepare_graphical_runtime
    # A guest compositor gets the host socket under a different name so it can
    # still create its own wayland-0 server socket.
    [[ "$VED_GUEST_WAYLAND_DISPLAY" == "ved-host-wayland-0" ]]
    grep -q '/ved-host-wayland-0$' "$VED_TEST_EXPORT_LOG"
    [[ "${VED_WAYLAND_EXPORT_FAILED:-0}" -eq 0 ]]

    VED_GUEST_SESSION_TYPE="x11"
    prepare_graphical_runtime
    [[ "$VED_GUEST_WAYLAND_DISPLAY" == "wayland-0" ]]
)

run_locale_key_parity() (
    set -e
    # shellcheck source=../lib/i18n.sh
    source "$PROJECT_ROOT/lib/i18n.sh"

    VED_MESSAGES=()
    # shellcheck source=../locale/en.sh
    source "$PROJECT_ROOT/locale/en.sh"
    local -a en_keys=()
    local key
    for key in "${!VED_MESSAGES[@]}"; do
        en_keys+=("$key")
    done

    VED_MESSAGES=()
    # shellcheck source=../locale/es.sh
    source "$PROJECT_ROOT/locale/es.sh"
    for key in "${en_keys[@]}"; do
        if [[ -z "${VED_MESSAGES[$key]+x}" ]]; then
            printf 'missing Spanish message key: %s\n' "$key" >&2
            return 1
        fi
    done
    ((${#en_keys[@]} > 0))
)

run_source_files_exist() (
    set -e
    local file path missing=0
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        file="$PROJECT_ROOT/$path"
        if [[ ! -f "$file" ]]; then
            printf 'missing sourced file: %s\n' "$path" >&2
            missing=1
        fi
    done < <(
        grep -hoE '\$(VED_ROOT|PROJECT_ROOT)/[A-Za-z0-9_./-]+\.sh' \
            "$VED" "$PROJECT_ROOT/tests/cli_test.sh" |
            sed -E 's/^\$(VED_ROOT|PROJECT_ROOT)\///' |
            sort -u
    )
    ((missing == 0))
)

run_ved() {
    local name="$1"
    local expected_status="$2"
    local expected_text="$3"
    shift 3

    should_run "$name" || {
        skip "$name"
        return 0
    }

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
run_ved docker_backend_alias 0 'ved 2.1.0' --backend oci --version
run_ved docker_image_option 0 'ved 2.1.0' --backend docker --image alpine:latest --version
run_ved help_docker 0 'Download an OCI image and run its rootfs with chroot' --help
run_ved help_docker_storage 0 '--docker-storage DIR' --help
run_ved powershell_invalid_shell 1 'Invalid Windows shell: fish' --backend powershell --shell fish --version
run_ved powershell_invalid_drive 1 'Invalid Windows drive letter: CC' --backend powershell --windows-drive CC --version
run_ved powershell_shell_alias 0 'ved 2.1.0' --backend powershell --shell powershell --version
run_ved powershell_shell_cmd 0 'ved 2.1.0' --backend powershell --shell cmd --version
run_ved powershell_shell_update 0 'ved 2.1.0' --backend powershell --shell update --version
run_ved powershell_shell_update_alias 0 'ved 2.1.0' --backend powershell --shell windows-update --version
run_ved powershell_shell_update_alias_wu 0 'ved 2.1.0' --backend powershell --shell wu --version
run_ved powershell_auto_option 0 'ved 2.1.0' --backend powershell --auto --version
run_ved powershell_auto_vm_option 0 'ved 2.1.0' --auto-vm --version
run_ved powershell_update_vm_alias 0 'ved 2.1.0' --update-vm --version
run_ved powershell_update_status_option 0 'ved 2.1.0' --backend powershell --update-status --version
run_ved powershell_invalid_kb 1 'Invalid KB number list' --backend powershell --auto --kb 1234 --version
run_ved powershell_auto_ro_conflict 1 '--auto needs write access' --backend powershell --auto --windows-ro --version
run_ved powershell_windows_write 0 'ved 2.1.0' --backend powershell --windows-write --version
run_ved help_powershell 0 'Mount a Windows partition and open pwsh or cmd' --help
run_ved help_shell_update 0 'pwsh, cmd or update' --help
run_ved help_update_auto 0 '--auto' --help
run_ved help_update_auto_vm 0 '--auto-vm' --help
run_ved help_update_status 0 '--update-status' --help
run_ved help_windows_ro 0 '--windows-ro' --help
run_ved zero_ram 1 'Invalid format. Use, for example: 8G, 16G or 8192M.' --ram 0M --version
run_ved efi_loader_traversal 1 'Invalid EFI loader path: ../etc/shadow' --efi-loader ../etc/shadow --version

run_case 'run directory isolation' run_directory_isolation
run_case 'windows backend helpers' run_windows_helpers
run_case 'windows update auto helpers' run_windows_update_auto_helpers
run_case 'windows update bash helper' run_windows_update_bash_helper
run_case 'windows update VM helpers' run_windows_update_vm_helpers
run_case 'shell auto menu' run_shell_auto_menu
run_case 'shell auto VM menu' run_shell_auto_vm_menu
run_case 'docker backend helpers' run_docker_helpers
run_case 'docker backend flow' run_docker_backend_flow
run_case 'wayland socket export' run_wayland_socket_export
run_case 'powershell install hint' run_powershell_hint
run_case 'backend locale messages' run_locale_messages
run_case 'locale key parity' run_locale_key_parity
run_case 'sourced files exist' run_source_files_exist
run_case 'CLI option normalization' run_cli_parsing
run_case 'desktop session helpers' run_session_helpers
run_case 'chroot guest identity helpers' run_chroot_identity_helpers
run_case 'chroot private system bus configuration' run_chroot_system_bus_config
run_case 'chroot login1 stub generator' run_login1_stub_generator
run_case 'graphical memlock limit helper' run_memlock_helper
run_case 'guest libgcrypt FIPS mask helper' run_fips_mask_helper
run_case 'graphical nspawn bus, memlock and FIPS hardening' run_nspawn_graphical_hardening

if ((failed)); then
    exit 1
fi

if ((skipped)); then
    printf '%s CLI regression tests passed, %s skipped.\n' "$passed" "$skipped"
else
    printf '%s CLI regression tests passed.\n' "$passed"
fi
