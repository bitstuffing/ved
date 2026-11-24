# Windows-partition shell backend: native PowerShell 7 (pwsh), or Wine cmd.
# This is deliberately NOT a VM: the NTFS partition is mounted and a Windows
# shell is started around it. It is a compatibility layer, not the installed
# Windows kernel (see the README for the exact limitations).

# Repeated here so standalone ShellCheck runs see the cross-file state.
: "${VED_UPDATE_VM:=0}"

PWSH_RUNNER=()
PWSH_RUNNER_HOME=""

# runuser does not reset HOME. Always resolve it from passwd at launch time and
# build a clean environment, so pwsh/Wine never inherit root's HOME.
powershell_user_home() {
    local user="$1" home

    [[ -n "$user" && "$user" != "root" ]] || return 1
    home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6)"
    [[ -n "$home" && "$home" != "/" ]] || home="${VED_GUI_HOME:-}"
    [[ -n "$home" && "$home" != "/" ]] || return 1
    printf '%s' "$home"
}

powershell_gui_runner() {
    local user="$1" home runtime=""

    home="$(powershell_user_home "$user")" || return 1
    [[ -z "${VED_GUI_UID:-}" ]] || runtime="/run/user/$VED_GUI_UID"

    PWSH_RUNNER_HOME="$home"
    PWSH_RUNNER=(
        runuser -u "$user" -- env -i
        "HOME=$home"
        "USER=$user"
        "LOGNAME=$user"
        "SHELL=/bin/bash"
        "PATH=/usr/local/bin:/usr/bin:/bin"
        "TERM=${TERM:-xterm-256color}"
        "LANG=${LANG:-C.UTF-8}"
        "XDG_DATA_HOME=$home/.local/share"
        "XDG_CONFIG_HOME=$home/.config"
        "POWERSHELL_TELEMETRY_OPTOUT=1"
        "POWERSHELL_UPDATECHECK=Off"
    )
    [[ -z "$runtime" ]] || PWSH_RUNNER+=("XDG_RUNTIME_DIR=$runtime")

    debug "shell environment: user=$user home=$home"
}

powershell_binary() {
    if have pwsh; then
        printf 'pwsh'
    elif have powershell; then
        printf 'powershell'
    else
        return 1
    fi
}

powershell_fail_missing() {
    printf '%s %s\n' "$(t error_prefix)" "$(t powershell_missing)" >&2
    powershell_install_hint >&2
    exit 1
}

powershell_existing_mountpoint() {
    local part="$1" mountpoint

    mountpoint="$(lsblk -nrpo MOUNTPOINT "$part" 2>/dev/null | head -n1 || true)"
    [[ -n "$mountpoint" && "$mountpoint" != "[SWAP]" ]] || return 0
    printf '%s' "$mountpoint"
}

# hiberfil.sys is created whenever hibernation is enabled, so it also exists on
# a Windows installation that was shut down cleanly with Fast Startup off. Its
# mere presence is NOT proof that the volume is hibernated. Only a large file
# with a real hibernation header counts when no NTFS probe is available.
powershell_is_hibernated() {
    local root="$1" file size magic
    for file in "$root/hiberfil.sys" "$root/Windows/System32/hiberfil.sys"; do
        [[ -f "$file" ]] || continue
        size="$(stat -c %s "$file" 2>/dev/null || printf '0')"
        ((size >= 1048576)) || continue
        # Read the header as hex: command substitution cannot hold NUL bytes,
        # and a zeroed hiberfil.sys is the common clean-shutdown case.
        magic="$(LC_ALL=C od -An -v -tx1 -N4 "$file" 2>/dev/null |
            tr -d ' \n')"
        case "$magic" in
            68696272|48494252|77616b65|57414b45) return 0 ;;
        esac
    done
    return 1
}

# ntfs-3g.probe performs the same safety check as an ntfs-3g read-write mount
# without writing anything. The kernel ntfs3 driver does not do this reliably,
# so prefer the probe whenever ntfs-3g is installed.
powershell_volume_writable() {
    local part="$1" root="$2" error
    if command -v ntfs-3g.probe >/dev/null 2>&1; then
        error="$(ntfs-3g.probe --readwrite "$part" 2>&1)" || {
            debug "ntfs-3g.probe refused read-write access: $error"
            return 1
        }
        return 0
    fi
    ! powershell_is_hibernated "$root"
}

powershell_mount_options() {
    local mode="$1"
    local uid="${VED_GUI_UID:-0}" gid="${VED_GUI_GID:-0}"
    local options="$mode,nosuid,nodev"

    if [[ -n "${VED_GUI_USER:-}" && "$uid" != "0" ]]; then
        options+=",uid=$uid,gid=$gid"
    fi
    printf '%s' "$options"
}

powershell_mount_partition() {
    local part="$1" target="$2" mount_type fstype options existing mount_error
    local -a mount_command=()

    existing="$(powershell_existing_mountpoint "$part")"
    if [[ -n "$existing" ]]; then
        VED_WINDOWS_MOUNT="$existing"
        info "$(t windows_using_existing_mount "$existing")"
        if [[ "$VED_WINDOWS_WRITE" -eq 1 ]]; then
            warn "$(t windows_write_existing_mount)"
        fi
        return 0
    fi

    fstype="$(lsblk -nrpo FSTYPE "$part" 2>/dev/null | head -n1 || true)"
    if [[ "${fstype,,}" == *bitlocker* ]]; then
        die "$(t windows_bitlocker "$part")"
    fi

    mount_type="$(windows_mount_type)" || die "$(t windows_ntfs_missing)"

    info "$(t windows_mounting)"
    mkdir -p "$target"
    umount_path "$target"

    options="$(powershell_mount_options ro)"
    mount_command=(mount -t "$mount_type" -o "$options" "$part" "$target")
    if [[ "$VED_DRY_RUN" -eq 1 ]]; then
        info "$(t dry_run)"
        print_command "${mount_command[@]}"
        printf '\n'
        VED_WINDOWS_MOUNT="$target"
        return 0
    fi

    if ! mount_error="$("${mount_command[@]}" 2>&1)"; then
        case "$mount_error" in
            *[Bb]it[Ll]ocker*) die "$(t windows_bitlocker "$part")" ;;
            *[Hh]ibernat*|*[Ff]ast[Rr]tart*|*[Dd]irty*)
                die "$(t windows_hibernated)" ;;
        esac
        debug "mount failed: $mount_error"
        die "$(t windows_mount_failed "$part")"
    fi
    cleanup_add_mount "$target"
    VED_WINDOWS_MOUNT="$target"

    if [[ "$VED_WINDOWS_WRITE" -eq 1 ]]; then
        powershell_volume_writable "$part" "$target" ||
            die "$(t windows_hibernated)"
        umount_path "$target"
        options="$(powershell_mount_options rw)"
        if mount_error="$(mount -t "$mount_type" -o "$options" "$part" "$target" 2>&1)"; then
            :
        else
            case "$mount_error" in
                *[Hh]ibernat*|*[Ff]ast[Rr]tart*|*[Dd]irty*)
                    die "$(t windows_hibernated)" ;;
                *)
                    debug "read-write mount failed: $mount_error"
                    die "$(t windows_mount_failed "$part")" ;;
            esac
        fi
        cleanup_add_mount "$target"
    fi

    info "$(t windows_ready "$target")"
}

# Generated .ps1 files are launched as the graphical user (via runuser), so they
# must live in a directory that user can traverse. VED_RUN_DIR is root-only.
powershell_register_script() {
    local file="$1"

    cleanup_add_file "$file"
    if [[ -n "${VED_GUI_UID:-}" && "${VED_GUI_UID}" != "0" ]]; then
        chown "$VED_GUI_UID:${VED_GUI_GID:-$VED_GUI_UID}" "$file" 2>/dev/null || true
    fi
    chmod 600 "$file" 2>/dev/null || true
}

powershell_script_dir() {
    printf '%s' "${VED_WINDOWS_SCRIPT_DIR:-$VED_RUN_DIR}"
}

powershell_prepare_history() {
    local script_dir history_file

    script_dir="$(powershell_script_dir)"
    history_file="$script_dir/PSReadLine_history.txt"
    : >"$history_file" || return 1
    powershell_register_script "$history_file"
    printf '%s' "$history_file"
}

# Generates a small startup script that maps the mount to a drive letter and
# moves the prompt there. Kept separate from the user's real PowerShell profile.
powershell_write_profile() {
    local drive="$VED_WINDOWS_DRIVE"
    local root="$VED_WINDOWS_MOUNT"
    local script_dir
    local profile

    script_dir="$(powershell_script_dir)"
    profile="$script_dir/ved-profile.ps1"

    cat >"$profile" <<PS1
\$ErrorActionPreference = 'Continue'
\$vedHistory = '$script_dir/PSReadLine_history.txt'
try {
    if (Get-Command -Name Set-PSReadLineOption -ErrorAction SilentlyContinue) {
        Set-PSReadLineOption -HistorySavePath \$vedHistory -ErrorAction Stop
    }
} catch {
    # History is optional; never let it break the shell.
}
\$vedRoot = '$root'
if (-not (Test-Path -LiteralPath \$vedRoot)) {
    Write-Warning "Windows mount not found: \$vedRoot"
} else {
    if (-not (Get-PSDrive -Name '$drive' -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name '$drive' -PSProvider FileSystem -Root \$vedRoot | Out-Null
    }
    Set-Location '${drive}:\'
}
function global:prompt { 'PS ${drive}:\> ' }
PS1

    powershell_register_script "$profile"
    printf '%s' "$profile"
}

# Update preparation terminal. This is native PowerShell 7 on Linux: it has
# network access, but it is NOT a booted Windows and cannot apply updates to the
# offline partition. It only downloads packages and generates a DISM script.
powershell_write_update_helper() {
    local script_dir helper

    script_dir="$(powershell_script_dir)"
    helper="$script_dir/ved-update.ps1"

    cat >"$helper" <<'PS1'
# Generated by ved. Do not edit; regenerate by starting the update shell again.
$ErrorActionPreference = 'Continue'

function Show-VedUpdateHelp {
    Write-Host @'
VED Windows Update preparation terminal
========================================

This is PowerShell 7 running on Linux. It has network access, but it cannot
apply updates to the offline Windows installation. Windows Update, USO and DISM
all need a booted Windows kernel and its servicing stack.

What works here:
  * Read the offline Windows build from the mounted partition.
  * Open the Microsoft Update Catalog for a KB number.
  * Download MSU/CAB packages into the staging directory.
  * Generate a .cmd file that applies staged packages with DISM.

What does NOT work here:
  * UsoClient.exe, wuauclt.exe or ms-settings:windowsupdate (no Windows services).
  * DISM /Image against the mounted partition (no Windows DISM on Linux).

Commands:
  Show-VedUpdateHelp                              This message
  Get-VedWindowsBuild                             Offline Windows version
  Get-VedCatalogUrl -KbNumber KB1234567           Catalog search URL
  Save-VedUpdatePackage -Url <https-url> [-Name <file.msu>]
                                                  Download one package
  Get-VedStagedUpdates                            List staged packages
  Write-VedApplyScript [-Output <path.cmd>]       Generate the DISM script

Afterwards boot Windows (or WinRE), open an administrator command prompt and
run the generated .cmd file. Review the DISM log that it writes. If WinRE
assigns a different letter to the Windows partition, set VED_IMAGE_DRIVE before
running the script (for example: set VED_IMAGE_DRIVE=D:).
'@
}

function Get-VedUpdateStageDir {
    $dir = $env:VED_UPDATE_STAGE_DIR
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) {
        throw "VED update staging directory is missing: $dir"
    }
    return $dir
}

function Get-VedWindowsBuild {
    $root = $env:VED_WINDOWS_MOUNT
    $kernel = Join-Path $root 'Windows/System32/ntoskrnl.exe'
    if (-not (Test-Path -LiteralPath $kernel)) {
        Write-Warning "Cannot read Windows/System32/ntoskrnl.exe from $root"
        return
    }
    try {
        $info = (Get-Item -LiteralPath $kernel).VersionInfo
        [pscustomobject]@{
            ProductVersion = $info.ProductVersion
            FileVersion    = $info.FileVersion
            FileBuildPart  = $info.FileBuildPart
        }
    } catch {
        Write-Warning "PE version information unavailable: $($_.Exception.Message)"
    }
}

function Get-VedCatalogUrl {
    param([Parameter(Mandatory = $true)][string]$KbNumber)
    if ($KbNumber -notmatch '^KB[0-9]{4,}$') {
        Write-Error "Expected a KB number such as KB1234567."
        return
    }
    "https://www.catalog.update.microsoft.com/Search.aspx?q=$KbNumber"
}

function Save-VedUpdatePackage {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [string]$Name
    )
    if ($Url -notmatch '^https://') {
        Write-Error "Only https:// URLs are accepted."
        return
    }
    if (-not $Name) {
        $Name = [System.IO.Path]::GetFileName(([Uri]$Url).LocalPath)
    }
    $Name = [System.IO.Path]::GetFileName($Name)
    if ($Name -notmatch '\.(msu|cab)$') {
        Write-Error "The package name must end in .msu or .cab: $Name"
        return
    }
    $destination = Join-Path (Get-VedUpdateStageDir) $Name
    Write-Host "Downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile $destination
    Get-Item -LiteralPath $destination | Select-Object Name, Length, LastWriteTime
}

function Get-VedStagedUpdates {
    Get-ChildItem -LiteralPath (Get-VedUpdateStageDir) -File |
        Where-Object { $_.Extension -in '.msu', '.cab' } |
        Sort-Object Name
}

function Write-VedApplyScript {
    param([string]$Output)
    if (-not $Output) {
        $Output = $env:VED_UPDATE_APPLY_SCRIPT
    }
    if (-not $Output) {
        Write-Error "No output path was given and VED_UPDATE_APPLY_SCRIPT is not set."
        return
    }
    $drive = $env:VED_WINDOWS_DRIVE
    if (-not $drive) { $drive = 'C' }
    $windowsPath = $env:VED_UPDATE_WINDOWS_PATH
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('@echo off')
    $lines.Add('setlocal')
    $lines.Add('rem Generated by ved. Run as administrator from Windows or WinRE.')
    $lines.Add('rem This applies the staged packages to the OFFLINE Windows image.')
    if ($windowsPath) {
        $lines.Add("set `"VEDPKGDIR=$windowsPath`"")
    } else {
        $lines.Add('if "%VED_PACKAGE_DIR%"=="" (')
        $lines.Add('  echo Set VED_PACKAGE_DIR to the folder containing the staged packages.')
        $lines.Add('  exit /b 1')
        $lines.Add(')')
        $lines.Add('set "VEDPKGDIR=%VED_PACKAGE_DIR%"')
    }
    $lines.Add('if not exist "%VEDPKGDIR%" (')
    $lines.Add('  echo Package folder not found: %VEDPKGDIR%')
    $lines.Add('  exit /b 1')
    $lines.Add(')')
    $lines.Add("set `"VEDIMGDRIVE=${drive}:`"")
    $lines.Add('if not "%VED_IMAGE_DRIVE%"=="" set "VEDIMGDRIVE=%VED_IMAGE_DRIVE%"')
    $lines.Add('set "VEDLOG=%VEDPKGDIR%\ved-dism.log"')
    $lines.Add('for %%P in ("%VEDPKGDIR%\*.msu" "%VEDPKGDIR%\*.cab") do (')
    $lines.Add('  echo Adding package: %%~nxP')
    $lines.Add('  dism /Image:%VEDIMGDRIVE%\ /Add-Package /PackagePath:"%%~fP" /LogPath:"%VEDLOG%"')
    $lines.Add('  if errorlevel 1 goto :failed')
    $lines.Add(')')
    $lines.Add('echo Done. Review %VEDLOG%')
    $lines.Add('exit /b 0')
    $lines.Add(':failed')
    $lines.Add('echo DISM failed. Review %VEDLOG%')
    $lines.Add('exit /b 1')
    $lines -join "`r`n" | Set-Content -LiteralPath $Output -Encoding ASCII
    Get-Item -LiteralPath $Output | Select-Object FullName, Length
}
PS1

    powershell_register_script "$helper"
    printf '%s' "$helper"
}

powershell_run_pwsh() {
    local profile="$1" command="$2" script="" binary script_dir
    local -a pwsh_args=(-NoLogo -NoProfile)
    local -a runner=()

    script_dir="$(powershell_script_dir)"

    binary="$(powershell_binary)" || powershell_fail_missing

    if [[ -n "${VED_GUI_USER:-}" ]]; then
        powershell_gui_runner "$VED_GUI_USER" ||
            die "$(t shell_user_invalid "$VED_GUI_USER")"
        runner=("${PWSH_RUNNER[@]}")
    fi

    if [[ -n "$command" ]]; then
        script="$script_dir/ved-command.ps1"
        {
            printf ". '%s'\n" "$profile"
            printf '%s\n' "$command"
        } >"$script"
        powershell_register_script "$script"
        pwsh_args+=(-File "$script")
    else
        pwsh_args+=(-NoExit -File "$profile")
    fi

    if [[ "$VED_DRY_RUN" -eq 1 ]]; then
        info "$(t dry_run)"
        print_command "${runner[@]}" "$binary" "${pwsh_args[@]}"
        printf '\n'
        return 0
    fi

    info "$(t powershell_profile "$VED_WINDOWS_DRIVE")"
    if [[ -n "$command" ]]; then
        info "$(t powershell_command "$command")"
    else
        info "$(t powershell_shell)"
    fi

    "${runner[@]}" "$binary" "${pwsh_args[@]}"
}

powershell_run_update() {
    local profile="$1" helper="$2" command="$3" script="" binary script_dir proxy_var
    local -a pwsh_args=(-NoLogo -NoProfile)
    local -a runner=()

    script_dir="$(powershell_script_dir)"
    binary="$(powershell_binary)" || powershell_fail_missing

    if [[ -n "${VED_GUI_USER:-}" ]]; then
        powershell_gui_runner "$VED_GUI_USER" ||
            die "$(t shell_user_invalid "$VED_GUI_USER")"
        runner=("${PWSH_RUNNER[@]}")
    else
        runner=(env)
    fi

    # The generated helpers read their configuration from the environment, so
    # they work with both the clean runuser environment and a plain root shell.
    runner+=(
        "VED_WINDOWS_DRIVE=${VED_WINDOWS_DRIVE:-C}"
        "VED_WINDOWS_MOUNT=${VED_WINDOWS_MOUNT:-}"
        "VED_UPDATE_STAGE_DIR=${VED_UPDATE_STAGE_DIR:-}"
        "VED_UPDATE_WINDOWS_PATH=${VED_UPDATE_WINDOWS_PATH:-}"
        "VED_UPDATE_APPLY_SCRIPT=${VED_UPDATE_APPLY_SCRIPT:-}"
    )

    # Keep proxy settings: downloads from the catalog often need them.
    for proxy_var in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY \
                     http_proxy https_proxy all_proxy no_proxy; do
        [[ -z "${!proxy_var:-}" ]] || runner+=("$proxy_var=${!proxy_var}")
    done

    script="$script_dir/ved-update-shell.ps1"
    {
        printf ". '%s'\n" "$profile"
        printf ". '%s'\n" "$helper"
        if [[ -n "$command" ]]; then
            printf '%s\n' "$command"
        else
            printf 'Show-VedUpdateHelp\n'
        fi
    } >"$script"
    powershell_register_script "$script"

    if [[ -n "$command" ]]; then
        pwsh_args+=(-File "$script")
    else
        pwsh_args+=(-NoExit -File "$script")
    fi

    if [[ "$VED_DRY_RUN" -eq 1 ]]; then
        info "$(t dry_run)"
        print_command "${runner[@]}" "$binary" "${pwsh_args[@]}"
        printf '\n'
        return 0
    fi

    info "$(t powershell_profile "$VED_WINDOWS_DRIVE")"
    if [[ -n "$command" ]]; then
        info "$(t powershell_update_command "$command")"
    else
        info "$(t powershell_update_shell)"
    fi

    "${runner[@]}" "$binary" "${pwsh_args[@]}"
}

powershell_plan_value() {
    local key="$1" file="$2"

    sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -n1 || true
}

powershell_show_update_status() {
    local status=""

    if [[ -f "$VED_WINDOWS_MOUNT/VEDUpdates/ved-update-status.txt" ]]; then
        status="$VED_WINDOWS_MOUNT/VEDUpdates/ved-update-status.txt"
    elif [[ -f "$VED_WINDOWS_MOUNT/VEDUpdates/ved-auto-apply.log" ]]; then
        status="$VED_WINDOWS_MOUNT/VEDUpdates/ved-auto-apply.log"
    fi

    if [[ -z "$status" ]]; then
        warn "$(t windows_update_no_status)"
        return 0
    fi

    info "$(t windows_update_status_title)"
    cat "$status"
    printf '\n'
}

powershell_windows_boot_entry() {
    local entries

    have efibootmgr || return 1

    # The verbose form includes the EFI device path, so a renamed or localized
    # boot entry is still recognized by bootmgfw.efi. Keep the plain form as a
    # fallback for older efibootmgr builds.
    entries="$(efibootmgr -v 2>/dev/null)" ||
        entries="$(efibootmgr 2>/dev/null)"

    printf '%s\n' "$entries" | awk '
        substr($0, 1, 4) != "Boot" { next }
        {
            id = substr($0, 5, 4)
            if (id !~ /^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$/) next
            marker = substr($0, 9, 1)
            if (marker != "*" && marker != " " && marker != "") next

            low = tolower($0)
            if (index(low, "windows boot manager") ||
                index(low, "\\efi\\microsoft\\boot\\bootmgfw.efi") ||
                index(low, "/efi/microsoft/boot/bootmgfw.efi") ||
                (index(low, "bootmgfw.efi") && index(low, "microsoft"))) {
                print id
                exit
            }
        }
    '
}

powershell_windows_bootloader() {
    local disk="$1" part fstype parttype probe mounted own loader rel
    local -a candidates=()

    while read -r part fstype parttype; do
        [[ -n "$part" ]] || continue
        case "${parttype,,}" in
            c12a7328-f81f-11d2-ba4b-00a0c93ec93b) ;;
            *)
                [[ "${fstype,,}" == vfat || "${fstype,,}" == fat32 ]] || continue
                ;;
        esac
        candidates+=("$part")
    done < <(lsblk -nrpo NAME,FSTYPE,PARTTYPE "$disk" 2>/dev/null)

    for part in "${candidates[@]}"; do
        own=0
        mounted="$(findmnt -nrno TARGET "$part" 2>/dev/null | head -n1 || true)"
        if [[ -n "$mounted" && -d "$mounted" ]]; then
            probe="$mounted"
        else
            probe="$VED_VM_DIR/windows-esp-probe"
            mkdir -p "$probe" 2>/dev/null || continue
            cleanup_add_dir "$probe"
            mount -o ro "$part" "$probe" 2>/dev/null || continue
            own=1
        fi

        for rel in EFI/Microsoft/Boot/bootmgfw.efi \
                   EFI/Microsoft/Boot/bootmgr.efi \
                   EFI/Boot/BootX64.efi; do
            [[ -f "$probe/$rel" ]] || continue
            # BootX64.efi alone is ambiguous: Linux distributors also install a
            # fallback loader there. Accept it only when the same ESP contains
            # Microsoft boot files or the loader itself identifies as Microsoft.
            if [[ "$rel" == EFI/Boot/BootX64.efi &&
                  ! -d "$probe/EFI/Microsoft" ]] &&
                ! grep -aqi microsoft "$probe/$rel" 2>/dev/null; then
                continue
            fi
            printf '%s|\\%s\n' "$part" "${rel//\//\\}"
            if ((own)); then
                umount_path "$probe"
            fi
            return 0
        done
        if ((own)); then
            umount_path "$probe"
        fi
    done
    return 1
}

powershell_partition_disk_number() {
    local part="$1" info="" disk="" num=""

    info="$(lsblk -nrpo PKNAME,PARTN "$part" 2>/dev/null | head -n1 || true)"
    read -r disk num <<<"$info"
    if [[ -z "$disk" || ! "$num" =~ ^[0-9]+$ ]]; then
        case "$part" in
            /dev/nvme*p[0-9]*|/dev/mmcblk*p[0-9]*)
                disk="${part%p*}"
                num="${part##*p}"
                ;;
            /dev/sd*[0-9]|/dev/vd*[0-9]|/dev/xvd*[0-9])
                disk="${part%[0-9]*}"
                num="${part##*[!0-9]}"
                ;;
        esac
    fi
    [[ -n "$disk" && "$num" =~ ^[0-9]+$ ]] || return 1
    printf '%s %s\n' "$disk" "$num"
}

powershell_add_windows_boot_entry() {
    local loader part efi_path numbers disk num output id

    [[ -n "$VED_DISK" ]] || return 1
    loader="$(powershell_windows_bootloader "$VED_DISK")" || return 1
    part="${loader%%|*}"
    efi_path="${loader#*|}"
    numbers="$(powershell_partition_disk_number "$part")" || return 1
    read -r disk num <<<"$numbers"

    output="$(efibootmgr -c -d "$disk" -p "$num" \
        -L 'Windows Boot Manager (VED)' -l "$efi_path" 2>&1)" || {
        debug "efibootmgr -c failed: $output"
        return 1
    }
    id="$(printf '%s\n' "$output" |
        sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\)\*.*/\1/p' | head -n1)"
    [[ -n "$id" ]] || return 1

    VED_CREATED_WIN_BOOT_ENTRY="$id"
    VED_CREATE_WIN_BOOT_ENTRY=1
    VED_UPDATE_BOOT_ENTRY="$id"
}

powershell_ensure_boot_entry() {
    local entry

    have efibootmgr || die "$(t windows_update_efibootmgr_missing)"
    [[ -n "$VED_UPDATE_BOOT_ENTRY" ]] && return 0

    entry="$(powershell_windows_boot_entry)" || entry=""
    if [[ -z "$entry" ]]; then
        if [[ "$VED_DRY_RUN" -eq 1 ]]; then
            info "$(t windows_update_boot_entry_dry_run)"
            VED_UPDATE_BOOT_ENTRY="XXXX"
            return 0
        fi
        info "$(t windows_update_creating_boot_entry)"
        powershell_add_windows_boot_entry ||
            die "$(t windows_update_boot_entry_create_failed)"
        entry="$VED_UPDATE_BOOT_ENTRY"
        info "$(t windows_update_boot_entry_created "$entry")"
    fi
    VED_UPDATE_BOOT_ENTRY="$entry"
}

powershell_boot_next_value() {
    efibootmgr 2>/dev/null |
        sed -n 's/^BootNext: *\([0-9A-Fa-f]\{4\}\).*/\1/p' |
        head -n1
}

powershell_remove_boot_restore() {
    local order_file="/etc/ved-update-boot-order"
    local helper="/usr/local/bin/ved-restore-boot-order"
    local unit="/etc/systemd/system/ved-update-restore-boot-order.service"
    local order=""

    if [[ -f "$order_file" ]]; then
        order="$(tr -d '\r\n' <"$order_file" 2>/dev/null || true)"
    fi

    if [[ "$VED_DRY_RUN" -eq 1 ]]; then
        print_command systemctl disable --now ved-update-restore-boot-order.service
        printf '\n'
        return 0
    fi

    if [[ "$order" =~ ^[0-9A-Fa-f,]+$ ]] && have efibootmgr; then
        efibootmgr -o "$order" >/dev/null 2>&1 || true
    fi
    if have systemctl; then
        systemctl disable --now ved-update-restore-boot-order.service >/dev/null 2>&1 || true
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    rm -f "$order_file" "$unit" "$helper" || true
}

powershell_remove_windows_startup() {
    local scripts_dir="$VED_WINDOWS_MOUNT/Windows/System32/GroupPolicy/Machine/Scripts"
    local launcher="$scripts_dir/Startup/ved-auto-update.cmd"
    local scripts_ini="$scripts_dir/scripts.ini"
    local temporary="$scripts_ini.ved.remove.tmp"

    if [[ "$VED_DRY_RUN" -eq 1 ]]; then
        print_command rm -f "$launcher"
        printf '\n'
        return 0
    fi

    rm -f "$launcher" || true
    [[ -f "$scripts_ini" ]] || return 0

    awk '
        /ved-auto-update\.cmd/ {
            if (match($0, /^[0-9]+/)) {
                drop[substr($0, RSTART, RLENGTH)] = 1
            }
            next
        }
        {
            if (match($0, /^[0-9]+/)) {
                idx = substr($0, RSTART, RLENGTH)
                if ((idx in drop) && /Parameters=/) {
                    next
                }
            }
            print
        }
    ' "$scripts_ini" >"$temporary" || return 0
    mv -f "$temporary" "$scripts_ini" || return 0
}

powershell_rollback_auto() {
    if [[ "$VED_DRY_RUN" -eq 1 ]]; then
        print_command efibootmgr -N
        printf '\n'
        powershell_remove_windows_startup
        powershell_remove_boot_restore
        return 0
    fi

    if have efibootmgr; then
        if [[ "$VED_CREATE_WIN_BOOT_ENTRY" -eq 1 &&
              -n "$VED_CREATED_WIN_BOOT_ENTRY" ]]; then
            efibootmgr -B -b "$VED_CREATED_WIN_BOOT_ENTRY" >/dev/null 2>&1 || true
            VED_CREATE_WIN_BOOT_ENTRY=0
            VED_CREATED_WIN_BOOT_ENTRY=""
        fi
        efibootmgr -N >/dev/null 2>&1 || true
    fi
    powershell_remove_windows_startup
    powershell_remove_boot_restore
}

powershell_prepare_boot_restore() {
    local boot_current boot_order entry remaining="" new_order
    local -a boot_entries=()
    local order_file="/etc/ved-update-boot-order"
    local helper="/usr/local/bin/ved-restore-boot-order"
    local unit="/etc/systemd/system/ved-update-restore-boot-order.service"

    boot_current="$(efibootmgr 2>/dev/null |
        sed -n 's/^BootCurrent: *\([0-9A-Fa-f]\{4\}\).*/\1/p' | head -n1)"
    boot_order="$(efibootmgr 2>/dev/null |
        sed -n 's/^BootOrder: *\([0-9A-Fa-f,]*\).*/\1/p' | head -n1)"

    if [[ -z "$boot_current" || -z "$boot_order" ]]; then
        warn "$(t windows_update_boot_restore_unavailable)"
        return 0
    fi

    IFS=',' read -r -a boot_entries <<<"$boot_order"
    for entry in "${boot_entries[@]}"; do
        [[ "$entry" =~ ^[0-9A-Fa-f]{4}$ ]] || {
            warn "$(t windows_update_boot_restore_unavailable)"
            return 0
        }
        [[ "$entry" == "$boot_current" ]] || remaining+=",$entry"
    done
    new_order="$boot_current$remaining"

    if [[ "$VED_DRY_RUN" -eq 1 ]]; then
        print_command printf '%s\n' "$boot_order"
        printf '\n'
        print_command efibootmgr -o "$new_order"
        printf '\n'
        print_command systemctl enable ved-update-restore-boot-order.service
        printf '\n'
        return 0
    fi

    if ! have systemctl; then
        warn "$(t windows_update_boot_restore_unavailable)"
        return 0
    fi

    printf '%s\n' "$boot_order" >"$order_file" || {
        powershell_rollback_auto
        die "$(t windows_update_boot_restore_failed)"
    }

    if ! cat >"$helper" <<'HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
order_file="/etc/ved-update-boot-order"
unit="/etc/systemd/system/ved-update-restore-boot-order.service"
[[ -f "$order_file" ]] || exit 0
order="$(tr -d '\r\n' <"$order_file")"
if [[ "$order" =~ ^[0-9A-Fa-f,]+$ ]] && command -v efibootmgr >/dev/null 2>&1; then
    efibootmgr -o "$order" >/dev/null 2>&1 || true
fi
rm -f "$order_file"
systemctl disable --now ved-update-restore-boot-order.service >/dev/null 2>&1 || true
rm -f "$unit" "$0"
systemctl daemon-reload >/dev/null 2>&1 || true
HELPER
    then
        powershell_rollback_auto
        die "$(t windows_update_boot_restore_failed)"
    fi
    chmod 755 "$helper" || {
        powershell_rollback_auto
        die "$(t windows_update_boot_restore_failed)"
    }

    if ! cat >"$unit" <<'UNIT'
[Unit]
Description=Restore UEFI boot order after VED automatic Windows Update
After=local-fs.target
ConditionPathExists=/etc/ved-update-boot-order

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ved-restore-boot-order
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
UNIT
    then
        powershell_rollback_auto
        die "$(t windows_update_boot_restore_failed)"
    fi

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable ved-update-restore-boot-order.service >/dev/null 2>&1 || {
        powershell_rollback_auto
        die "$(t windows_update_boot_restore_failed)"
    }

    if [[ "$new_order" != "$boot_order" ]]; then
        efibootmgr -o "$new_order" >/dev/null || {
            powershell_rollback_auto
            die "$(t windows_update_boot_restore_failed)"
        }
    fi
    info "$(t windows_update_boot_restore_ready)"
}

powershell_write_auto_apply() {
    local kb="$1" candidate="$2" package_names="$3" action="${4:-reboot}"
    local stage="$VED_UPDATE_STAGE_DIR"
    local windows_path="$VED_UPDATE_WINDOWS_PATH"
    local gpt_ini="$VED_WINDOWS_MOUNT/Windows/System32/GroupPolicy/gpt.ini"
    local apply_linux="$stage/ved-auto-apply.ps1"
    local apply_windows="$windows_path\\ved-auto-apply.ps1"
    local scripts_dir="$VED_WINDOWS_MOUNT/Windows/System32/GroupPolicy/Machine/Scripts"
    local startup_dir="$scripts_dir/Startup"
    local launcher="$startup_dir/ved-auto-update.cmd"
    local launcher_windows='C:\Windows\System32\GroupPolicy\Machine\Scripts\Startup\ved-auto-update.cmd'
    local scripts_ini="$scripts_dir/scripts.ini"
    local status_windows="$windows_path\\ved-update-status.txt"
    local stale gpt_version index candidate_index package_name
    local package_list="" first_package=1
    local -a planned_packages=()

    [[ "$action" == reboot || "$action" == shutdown ]] ||
        die "$(t windows_update_plan_invalid)"

    IFS=' ' read -r -a planned_packages <<<"$3"
    for package_name in "${planned_packages[@]}"; do
        [[ -n "$package_name" ]] || continue
        ((first_package)) || package_list+=$'\n'
        package_list+="    '${package_name//\'/\'\'}'"
        first_package=0
    done

    mkdir -p "$startup_dir" ||
        die "$(t windows_update_gpo_failed)"

    if [[ -f "$gpt_ini" ]]; then
        gpt_version="$(sed -n 's/^Version=[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
            "$gpt_ini" 2>/dev/null | head -n1 || true)"
        if [[ "$gpt_version" =~ ^[0-9]+$ ]]; then
            gpt_version=$((gpt_version + 1))
            awk -v version="$gpt_version" \
                '!done && /^Version=/ { print "Version=" version; done=1; next } { print }' \
                "$gpt_ini" >"$gpt_ini.ved.tmp" ||
                die "$(t windows_update_gpo_failed)"
            mv -f "$gpt_ini.ved.tmp" "$gpt_ini" ||
                die "$(t windows_update_gpo_failed)"
        fi
    else
        printf '[General]\r\nVersion=1\r\n' >"$gpt_ini" ||
            die "$(t windows_update_gpo_failed)"
    fi

    if [[ -f "$scripts_ini" ]]; then
        cp -f "$scripts_ini" "$scripts_ini.ved.bak" ||
            die "$(t windows_update_gpo_failed)"
        while IFS= read -r stale; do
            [[ -n "$stale" ]] || continue
            awk -v idx="$stale" \
                '$0 !~ ("^" idx "CmdLine=") && $0 !~ ("^" idx "Parameters=")' \
                "$scripts_ini" >"$scripts_ini.ved.tmp" ||
                die "$(t windows_update_gpo_failed)"
            mv -f "$scripts_ini.ved.tmp" "$scripts_ini" ||
                die "$(t windows_update_gpo_failed)"
        done < <(sed -n 's/^\([0-9][0-9]*\)CmdLine=.*ved-auto-update\.cmd.*/\1/p' \
            "$scripts_ini" 2>/dev/null | sort -u)
    fi

    index=""
    for candidate_index in {100..999}; do
        if ! grep -q "^${candidate_index}CmdLine=" "$scripts_ini" 2>/dev/null; then
            index="$candidate_index"
            break
        fi
    done
    [[ -n "$index" ]] || die "$(t windows_update_gpo_failed)"

    printf '@echo off\r\npowershell.exe -NoProfile -ExecutionPolicy Bypass -File "%s"\r\nexit /b %%errorlevel%%\r\n' \
        "$apply_windows" >"$launcher" ||
        die "$(t windows_update_gpo_failed)"

    if ! grep -q '^\[Startup\]' "$scripts_ini" 2>/dev/null; then
        printf '\r\n[Startup]\r\n' >>"$scripts_ini"
    fi
    printf '%sCmdLine=%s\r\n%sParameters=\r\n' \
        "$index" "$launcher_windows" "$index" >>"$scripts_ini" ||
        die "$(t windows_update_gpo_failed)"

    cat >"$apply_linux" <<EOF
\$ErrorActionPreference = 'Continue'
\$stage = '$windows_path'
\$status = '$status_windows'
\$log = Join-Path \$stage 'ved-auto-apply.log'
\$kb = '$kb'
\$target = '$candidate'
\$iniIndex = '$index'
\$packageNames = @(
$package_list
)

function Write-VedStatus {
    param([string]\$Text)
    Add-Content -LiteralPath \$status -Value ((Get-Date -Format o) + ' ' + \$Text) -Encoding ASCII
}

function Remove-VedStartupEntry {
    \$startup = Join-Path \$env:SystemRoot 'System32\GroupPolicy\Machine\Scripts\Startup\ved-auto-update.cmd'
    \$scriptsIni = Join-Path \$env:SystemRoot 'System32\GroupPolicy\Machine\Scripts\scripts.ini'
    Remove-Item -LiteralPath \$startup -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath \$scriptsIni) {
        \$pattern = '^' + \$iniIndex + '(CmdLine|Parameters)='
        \$kept = @()
        foreach (\$line in @(Get-Content -LiteralPath \$scriptsIni -ErrorAction SilentlyContinue)) {
            if (\$line -match \$pattern) { continue }
            \$kept += \$line
        }
        Set-Content -LiteralPath \$scriptsIni -Value \$kept -Encoding ASCII
    }
}

Set-Content -LiteralPath \$status -Value ((Get-Date -Format o) + ' START VED automatic Windows Update') -Encoding ASCII
Write-VedStatus ('TARGET ' + \$kb + ' ' + \$target)
try {
    if (\$packageNames.Count -eq 0) {
        throw 'No staged MSU/CAB packages were selected.'
    }
    \$dism = Join-Path \$env:SystemRoot 'System32\dism.exe'
    foreach (\$name in \$packageNames) {
        \$package = Join-Path \$stage \$name
        if (-not (Test-Path -LiteralPath \$package -PathType Leaf)) {
            throw ('Missing staged package: ' + \$name)
        }
        Write-VedStatus ('ADD ' + \$name)
        & \$dism /Online /Add-Package /PackagePath:"\$package" /NoRestart /LogPath:"\$log"
        if (\$LASTEXITCODE -ne 0) {
            throw ('DISM failed for ' + \$name + ' with exit code ' + \$LASTEXITCODE)
        }
    }
    Write-VedStatus ('SUCCESS ' + \$kb + ' ' + \$target)
} catch {
    Write-VedStatus ('FAILED ' + \$_.Exception.Message)
} finally {
    Remove-VedStartupEntry
}
Start-Sleep -Seconds 5
\$shutdown = Join-Path \$env:SystemRoot 'System32\shutdown.exe'
if ('$action' -eq 'shutdown') {
    & \$shutdown /s /t 20 /f /c "VED Windows Update finished in the VM"
} else {
    & \$shutdown /r /t 20 /f /c "VED Windows Update finished; returning to Linux"
}
EOF
}

powershell_validate_auto_plan() {
    local kb="$1" candidate="$2" packages="$3"
    local name
    local -a names=()

    [[ "$kb" =~ ^(KB[0-9]{4,})(,KB[0-9]{4,})*$ ]] ||
        die "$(t windows_update_plan_invalid)"
    [[ "$candidate" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] ||
        die "$(t windows_update_plan_invalid)"

    IFS=' ' read -r -a names <<<"$packages"
    ((${#names[@]} > 0)) || die "$(t windows_update_plan_invalid)"
    for name in "${names[@]}"; do
        [[ "$name" =~ ^[A-Za-z0-9._-]+\.(msu|cab)$ ]] ||
            die "$(t windows_update_plan_invalid)"
    done
}

powershell_update_auto() {
    local bash_helper plan_env discovery_log count kb candidate packages boot_entry boot_next
    local -a helper_args=()

    if ! have curl && ! have wget; then
        die "$(t windows_update_http_missing)"
    fi
    boot_next="$(powershell_boot_next_value)"
    [[ -z "$boot_next" ]] ||
        die "$(t windows_update_bootnext_busy "$boot_next")"

    bash_helper="$VED_ROOT/lib/windows_update.sh"
    plan_env="$VED_UPDATE_STAGE_DIR/ved-update-plan.env"
    discovery_log="$VED_UPDATE_STAGE_DIR/ved-update-discovery.log"

    helper_args=(
        --windows-root "$VED_WINDOWS_MOUNT"
        --stage-dir "$VED_UPDATE_STAGE_DIR"
    )
    [[ -z "$VED_UPDATE_KB" ]] || helper_args+=(--kb "$VED_UPDATE_KB")

    if [[ "$VED_DRY_RUN" -eq 1 ]]; then
        info "$(t windows_update_dry_run)"
        helper_args+=(--plan-only)
        print_command bash "$bash_helper" "${helper_args[@]}"
        printf '\n'
        powershell_ensure_boot_entry
        boot_entry="$VED_UPDATE_BOOT_ENTRY"
        powershell_prepare_boot_restore
        print_command efibootmgr -n "$boot_entry"
        printf '\n'
        print_command systemctl reboot
        printf '\n'
        return 0
    fi

    info "$(t windows_update_checking)"
    if ! bash "$bash_helper" "${helper_args[@]}" 2>&1 | tee "$discovery_log"; then
        die "$(t windows_update_discovery_failed)"
    fi
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
    info "$(t windows_update_auto_warning)"
    confirm_key windows_update_auto_confirm 0 || {
        info "$(t aborted)"
        return 0
    }

    powershell_write_auto_apply "$kb" "$candidate" "$packages"
    info "$(t windows_update_apply_ready "$VED_UPDATE_APPLY_SCRIPT")"
    powershell_ensure_boot_entry
    boot_entry="$VED_UPDATE_BOOT_ENTRY"
    powershell_prepare_boot_restore
    info "$(t windows_update_boot_entry_found "$boot_entry")"
    info "$(t windows_update_setting_bootnext)"
    if ! efibootmgr -n "$boot_entry"; then
        powershell_rollback_auto
        die "$(t windows_update_bootnext_failed)"
    fi

    sync
    umount_path "$VED_WINDOWS_MOUNT"
    info "$(t windows_update_rebooting)"
    if have systemctl; then
        if ! systemctl reboot; then
            powershell_rollback_auto
            die "$(t windows_update_reboot_failed)"
        fi
    else
        if ! reboot; then
            powershell_rollback_auto
            die "$(t windows_update_reboot_failed)"
        fi
    fi
}

powershell_run_cmd() {
    local command="$1" prefix
    local uid="${VED_GUI_UID:-0}" gid="${VED_GUI_GID:-0}"
    local -a runner=()
    local -a wine_command=(wine cmd.exe)

    [[ -n "${VED_GUI_USER:-}" ]] || die "$(t wine_needs_user)"
    powershell_gui_runner "$VED_GUI_USER" ||
        die "$(t shell_user_invalid "$VED_GUI_USER")"
    prefix="$PWSH_RUNNER_HOME/.local/share/ved/wine"

    runner=("${PWSH_RUNNER[@]}")
    runner+=(
        "WINEPREFIX=$prefix"
        "WINEDEBUG=-all"
        "WINEDLLOVERRIDES=mscoree,mshtml="
    )

    if [[ -n "$command" ]]; then
        wine_command+=(/c "$command")
    fi

    if [[ "$VED_DRY_RUN" -eq 1 ]]; then
        info "$(t dry_run)"
        print_command "${runner[@]}" wineboot -u
        printf '\n'
        print_command "${runner[@]}" "${wine_command[@]}"
        printf '\n'
        return 0
    fi

    install -d -m 700 -o "$uid" -g "${gid:-$uid}" "$prefix" ||
        die "$(t wine_prefix_failed)"
    timeout 90 "${runner[@]}" wineboot -u >/dev/null 2>&1 ||
        warn "$(t wine_prefix_failed)"

    # Wine's own C: stays intact; the Windows partition is exposed as W:.
    ln -sfn "$VED_WINDOWS_MOUNT" "$prefix/dosdevices/w:" ||
        die "$(t wine_prefix_failed)"

    if [[ -n "$command" ]]; then
        info "$(t cmd_command "$command")"
    else
        info "$(t cmd_shell)"
    fi

    "${runner[@]}" "${wine_command[@]}"
}

backend_powershell() {
    local profile command="${VED_COMMAND:-}" mount_dir script_dir dir resolved_home helper="" staged

    detect_graphical_user_optional

    if [[ -n "${VED_GUI_USER:-}" ]]; then
        resolved_home="$(powershell_user_home "$VED_GUI_USER")" ||
            die "$(t shell_user_invalid "$VED_GUI_USER")"
        VED_GUI_HOME="$resolved_home"
    fi

    # Native pwsh is only needed for the interactive shells. The fully closed
    # automatic mode uses bash + curl/wget on Linux and Windows PowerShell
    # after boot.
    if [[ "$VED_SHELL" == "pwsh" ||
          ( "$VED_SHELL" == "update" && "$VED_UPDATE_AUTO" -eq 0 &&
            "$VED_UPDATE_SHOW_STATUS" -eq 0 ) ]]; then
        powershell_binary >/dev/null 2>&1 || powershell_fail_missing
    fi

    if [[ -n "$VED_ROOT_PARTITION" ]]; then
        [[ -b "$VED_ROOT_PARTITION" ]] ||
            die "$(t partition_missing "$VED_ROOT_PARTITION")"
    else
        select_disk
        detect_windows_partition
    fi

    if [[ "$VED_WINDOWS_WRITE" -eq 1 ]]; then
        warn "$(t windows_writable_warning)"
    fi

    show_configuration

    # Check UEFI prerequisites before touching the Windows filesystem. A missing
    # efibootmgr package cannot be fixed by staging packages. The boot entry is
    # only created after the update has been found and confirmed.
    if [[ "$VED_UPDATE_AUTO" -eq 1 && "$VED_UPDATE_VM" -eq 0 ]]; then
        have efibootmgr || die "$(t windows_update_efibootmgr_missing)"
    fi

    # The private run directory is root-only. Put both the mount and the
    # generated .ps1 files somewhere the unprivileged shell user can traverse.
    # The script directory must be separate from the mountpoint: mounting on
    # top of it would hide anything written there before the mount.
    mount_dir="$(make_temp_dir "${TMPDIR:-/tmp}/ved-windows.XXXXXX")"
    script_dir="$(make_temp_dir "${TMPDIR:-/tmp}/ved-shell.XXXXXX")"

    if [[ -n "${VED_GUI_UID:-}" && "${VED_GUI_UID}" != "0" ]]; then
        for dir in "$mount_dir" "$script_dir"; do
            chown "$VED_GUI_UID:${VED_GUI_GID:-$VED_GUI_UID}" "$dir" ||
                die "$(t windows_temp_failed "$dir")"
        done
    fi
    VED_WINDOWS_SCRIPT_DIR="$script_dir"
    powershell_prepare_history >/dev/null ||
        die "$(t windows_temp_failed "$script_dir")"

    powershell_mount_partition "$VED_ROOT_PARTITION" "$mount_dir"
    VED_WINDOWS_MOUNT="${VED_WINDOWS_MOUNT:-$mount_dir}"

    if [[ "$VED_UPDATE_SHOW_STATUS" -eq 1 ]]; then
        powershell_show_update_status
        return 0
    fi

    profile="$(powershell_write_profile)"

    if [[ "$VED_SHELL" == "update" ]]; then
        # Prefer staging on the Windows partition so the generated .cmd and the
        # packages are still there after booting into Windows/WinRE.
        if [[ "$VED_WINDOWS_WRITE" -eq 1 ]]; then
            staged="$VED_WINDOWS_MOUNT/VEDUpdates"
            if mkdir -p "$staged" 2>/dev/null; then
                VED_UPDATE_STAGE_DIR="$staged"
                VED_UPDATE_WINDOWS_PATH="${VED_WINDOWS_DRIVE}:\\VEDUpdates"
            else
                warn "$(t powershell_update_stage_failed "$staged")"
            fi
        fi
        if [[ -z "$VED_UPDATE_STAGE_DIR" ]]; then
            VED_UPDATE_STAGE_DIR="$script_dir/updates"
            mkdir -p "$VED_UPDATE_STAGE_DIR" ||
                die "$(t windows_temp_failed "$VED_UPDATE_STAGE_DIR")"
            VED_UPDATE_WINDOWS_PATH=""
            warn "$(t powershell_update_stage_ro)"
        fi
        if [[ "$VED_UPDATE_AUTO" -eq 1 ]]; then
            VED_UPDATE_APPLY_SCRIPT="$VED_UPDATE_STAGE_DIR/ved-auto-apply.ps1"
        else
            VED_UPDATE_APPLY_SCRIPT="$VED_UPDATE_STAGE_DIR/apply-ved-updates.cmd"
        fi
        helper="$(powershell_write_update_helper)"
    fi

    case "$VED_SHELL" in
        cmd) powershell_run_cmd "$command" ;;
        update)
            if [[ "$VED_UPDATE_VM" -eq 1 ]]; then
                powershell_update_vm
            elif [[ "$VED_UPDATE_AUTO" -eq 1 ]]; then
                powershell_update_auto
            else
                powershell_run_update "$profile" "$helper" "$command"
            fi
            ;;
        *) powershell_run_pwsh "$profile" "$command" ;;
    esac
}
