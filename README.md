# ved — Virtual External Devices

**Boot a physical disk, a partition or a disk image as a virtual machine, enter an installed Linux system as a chroot / container, or open a PowerShell / cmd prompt on a Windows partition — from one command.**

`ved` is a single, modular Bash tool that wraps QEMU/KVM, `chroot`, `systemd-nspawn`
and `pwsh`/Wine behind a friendly, interactive menu. It auto-detects your disks, EFI loaders, GPUs,
TPM and USB devices, installs missing OS packages for your distribution (PowerShell is a
deliberate exception), and asks for the administrator password only once.

---

## Table of contents

- [Features](#features)
- [Requirements](#requirements)
- [Supported distributions](#supported-distributions)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Backends](#backends)
- [PowerShell / cmd on a Windows partition (no VM)](#powershell--cmd-on-a-windows-partition-no-vm)
  - [Installing pwsh](#installing-pwsh)
  - [What the backend does](#what-the-backend-does)
  - [Verifying the PowerShell environment](#verifying-the-powershell-environment)
  - [Limitations — please read](#limitations--please-read)
- [Interactive flow](#interactive-flow)
- [USB devices (webcam, Bluetooth/AirPods, phones)](#usb-devices-webcam-bluetoothairpods-phones)
- [Display and OpenGL](#display-and-opengl)
- [TPM and Secure Boot](#tpm-and-secure-boot)
- [Languages](#languages)
- [Graphical desktop sessions (chroot / nspawn)](#graphical-desktop-sessions-chroot--nspawn)
- [nspawn status bar](#nspawn-status-bar-ctrla-prefix)
- [Options](#options)
- [Examples](#examples)
- [Project layout](#project-layout)
- [Development and testing](#development-and-testing)
  - [What the suite covers](#what-the-suite-covers)
  - [Adding a test](#adding-a-test)
  - [Manual smoke tests](#manual-smoke-tests)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## Features

- **One entry point**: `./ved`. Run it with no arguments for an interactive menu.
- **Physical disks, partitions or images**: pass a whole disk (`--disk`), a Linux root
  partition (`--partition`) or a disk image (`--image`).
- **Four backends**: QEMU/KVM, `chroot`, `systemd-nspawn`, and a Windows shell
  backend that mounts an NTFS partition and opens **PowerShell 7 (`pwsh`)** or
  **cmd (via Wine)** — with no QEMU process at all.
- **Automatic detection** of disks, EFI system partitions, EFI loaders, guest OS,
  DRM render nodes, hardware TPM and USB devices.
- **OpenGL acceleration** through `virtio-vga-gl` and a selected DRM render node,
  with a safe fallback chain (`spice-gl` → `spice` → …).
- **TPM** via hardware passthrough or a software TPM (`swtpm`), and optional
  **Secure Boot** OVMF firmware.
- **USB auto-passthrough**: webcam and Bluetooth are passed automatically; Android
  phones are detected and offered. Includes a host-side Bluetooth reset trick so
  wireless earbuds (e.g. AirPods) work inside the VM.
- **Storage modes**: temporary (discard changes on exit) or persistent.
- **Automatic dependency installation** for your distribution, or `--no-install`.
- **Internationalization** with English and Spanish out of the box.
- **Dry run** (`--dry-run`) to print the exact command without running it.
- **Administrator password asked once**, then re-executes through `sudo` cleanly.
- **Graphical desktop sessions** in chroot/nspawn: launch a full desktop session
  (GNOME, KDE Plasma, Xfce, …) or a single app from an installed system, with GPU
  acceleration, Wayland/X11, audio and input devices.
- **GNOME 49+ aware**: ved inspects the installed system and, when GNOME no longer
  supports X11, starts the shell as a nested Wayland window instead of Xephyr.
- **nspawn status bar** (Ctrl+A prefix): when booting a full system with `--boot`,
  a persistent status bar shows machine name/PID and lets you Stop/Reboot/Poweroff/Quit
  without leaving the terminal.
- **Windows partition shell**: mounts the NTFS/BitLocker-unlocked partition read-only
  by default, maps it to a `C:` PSDrive in PowerShell (or `W:` in Wine cmd), and
  detects already-mounted partitions so it can reuse them.

## Requirements

- Linux with **Bash 4.3+**.
- **KVM** (`/dev/kvm`) for hardware acceleration — falls back to TCG (slow) if absent.
- A graphical session if you want a windowed VM (SPICE/GTK viewer) or a graphical
  chroot/nspawn session.

`ved` checks for its dependencies and can install them automatically. The logical
dependencies are:

| Purpose | Packages (logical) |
| --- | --- |
| Virtualization | `qemu-system-x86` / `qemu-full` / `qemu` |
| UEFI firmware | `OVMF` (`edk2-ovmf`, `ovmf`, …) |
| FAT tooling | `dosfstools` (`mkfs.vfat`) |
| Core tooling | `util-linux`, `coreutils`, `findutils` |
| SPICE viewer (optional) | `virt-viewer` (`remote-viewer`, `virt-viewer`, `spicy`) |
| Software TPM (optional) | `swtpm` |
| Containers (nspawn backend) | `systemd-container` |
| Windows shell (powershell backend) | `pwsh` (PowerShell 7) — **not auto-installed**, see below |
| NTFS access (powershell backend) | `ntfs-3g` (or kernel `ntfs3` support) |
| cmd shell (optional) | `wine` |
| Nested X11 (optional) | `Xephyr` (only for guests that still support X11 sessions) |

`pwsh` must be installed manually. `ved` never tries to add a `powershell` package
automatically, because on Fedora/RHEL that name is either missing or not the
PowerShell 7 runtime. See [Installing pwsh](#installing-pwsh).

**Requirements inside the installed (guest) system** for a full graphical desktop:

| Guest desktop | What it needs |
| --- | --- |
| GNOME 49+ (Ubuntu 25.10+, Fedora 43+, …) | `mutter-devkit` (Ubuntu: package `mutter-dev-bin`) |
| GNOME ≤ 48, KDE Plasma, Xfce, MATE, Cinnamon, … | the usual session binary (`gnome-session`, `startplasma-x11`, `startxfce4`, …) |
| Any | `dbus-run-session` (package `dbus-daemon` / `dbus-x11`) |

## Supported distributions

Package names are resolved automatically for these families:

Debian/Ubuntu/Mint/Pop/Kali · Fedora/RHEL/CentOS/Nobara/Rocky/AlmaLinux ·
Arch/Manjaro/EndeavourOS/CachyOS · openSUSE/SLES · Alpine · Void.

If the package manager is unknown, use `--no-install` and provide the tools yourself.

## Installation

```bash
git clone https://github.com/bitstuffing/virtual-external-devices.git
cd virtual-external-devices
chmod +x ved
./ved
```

There is nothing to build. You can also symlink `ved` into your `PATH`:

```bash
sudo ln -s "$PWD/ved" /usr/local/bin/ved
```

## Quick start

Run it with no options — the interactive menu guides you through everything:

```bash
./ved
```

The tool will:

1. scan and list your physical disks, and ask which one to use;
2. ask what to do with it (virtual machine, chroot, container or Windows shell);
3. ask for the administrator password (once);
4. mount the system, inspect it and detect the EFI loader, guest OS, desktop,
   memory, CPUs and storage mode;
5. show a summary of exactly what it is about to launch, and start it.

## Backends

| Backend | Flag | What it does |
| --- | --- | --- |
| **QEMU/KVM** | `-b qemu` | Runs a physical disk, a partition or an image as a full virtual machine (UEFI + SPICE). |
| **chroot** | `-b chroot` | Mounts an installed Linux system and enters it with `chroot`. Can bind the host display/audio with `--graphical`. |
| **systemd-nspawn** | `-b nspawn` | Mounts an installed Linux system and runs it as a container; `--boot` boots it with systemd. |
| **Windows shell** | `-b powershell` (aliases: `pwsh`, `windows`) | Mounts a Windows partition and opens native PowerShell 7 (`--shell pwsh`) or Wine cmd (`--shell cmd`). No QEMU, no graphics stack. |

> **Security:** `chroot` is not a security boundary. It runs with host privileges and exposes host kernel interfaces to the installed system. Use it only with installations you trust; use QEMU for untrusted disks or images.

## PowerShell / cmd on a Windows partition (no VM)

This backend answers a common question: *"can I use a Windows partition like a
chroot, just to get a `cmd` or PowerShell prompt without booting a whole VM?"*

**A literal Windows chroot is not possible.** `chroot` and `systemd-nspawn` share
the host's Linux kernel; Windows executables need the Windows NT kernel. There is
no way to run the partition's own `C:\Windows\System32\cmd.exe` or
`powershell.exe` on a Linux kernel. What `ved` can do instead is mount the
partition and run a **Windows-compatible shell around it**. Two modes are
available, and neither starts QEMU:

| Mode | Command | What it is | What you get |
| --- | --- | --- | --- |
| `pwsh` (default) | `pwsh -NoLogo -NoProfile -NoExit -File <ved-profile.ps1>` | Microsoft's **native Linux PowerShell 7** | A real PowerShell prompt. `ved` injects a small startup script that creates a `C:` PSDrive pointing at the mount and moves you there, so the prompt reads `PS C:\>`. |
| `cmd` | `wine cmd.exe` | **Wine's** `cmd.exe` reimplementation | A familiar `cmd` prompt. The Windows partition is exposed as `W:` (Wine keeps its own `C:` intact). Requires `wine`. |

```bash
# PowerShell 7 on the detected Windows partition of a disk
./ved -b powershell -d /dev/nvme0n1

# Explicit partition; read-only is already the default
./ved -b powershell -p /dev/nvme0n1p3

# Allow writes (only when Windows is shut down cleanly, not hibernated)
./ved -b powershell -p /dev/nvme0n1p3 --windows-write

# Reassert read-only, e.g. after a config file enabled writes
./ved -b powershell -p /dev/nvme0n1p3 --windows-ro

# Map the partition to D: instead of C:
./ved -b powershell -p /dev/nvme0n1p3 --windows-drive D

# Wine cmd instead of PowerShell
./ved -b powershell -p /dev/nvme0n1p3 --shell cmd

# One-shot command: ved dot-sources the C: mapping first, then runs your command
./ved -b powershell -p /dev/nvme0n1p3 -c 'Get-ChildItem C:\Windows | Select-Object -First 5'

# Inspect the mount and shell commands without running them
./ved -b powershell -p /dev/nvme0n1p3 --shell cmd --dry-run
```

### Installing pwsh

PowerShell 7 is not in most distributions' default repositories. `ved` will
never run `dnf install powershell` for you; install it once, then re-run `ved`.

Fedora / RHEL / Nobara:

```bash
curl -fsSL -O https://packages.microsoft.com/config/rhel/9/packages-microsoft-prod.rpm
sudo rpm -i packages-microsoft-prod.rpm
sudo dnf install -y powershell
pwsh --version
```

Debian / Ubuntu (adjust the version in the URL if needed):

```bash
wget -q https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb
sudo dpkg -i packages-microsoft-prod.deb
sudo apt-get update
sudo apt-get install -y powershell
```

Arch: `yay -S powershell-bin`. For other distributions, see the
[official installation docs](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux).
If you prefer not to install PowerShell, use `--shell cmd`; Wine comes from the
standard repositories.

### What the backend does

1. **Finds the partition.** If `--partition` is not given, it scans the selected
   disk for NTFS/BitLocker partitions and probes them read-only for
   `Windows\System32` to identify the actual system partition. If several look
   plausible, you are asked to choose.
2. **Mounts it safely.** The default is **read-only** (`-o ro,nosuid,nodev`).
   Use `--windows-write` for read-write; `ved` refuses if `hiberfil.sys` exists
   (Windows Fast Startup), because writing to a hibernated NTFS volume corrupts it.
   If the partition is already mounted by your desktop, `ved` reuses that mount
   point instead of mounting it twice.
3. **Creates private helper files.** The startup script is written to a
   user-owned `/tmp/ved-shell.XXXXXX` directory, not to the root-only
   `/run/ved` runtime directory. A private `PSReadLine_history.txt` is created
   there too. Your real PowerShell profile is never touched, and in command mode
   (`-c`) the startup script is dot-sourced before your command.
4. **Drops privileges correctly.** `pwsh` and Wine are started with `runuser`
   and a clean environment: `HOME`, `USER` and `LOGNAME` are re-read from
   `passwd`, `XDG_DATA_HOME`/`XDG_CONFIG_HOME` point to that home, and no root
   variables are inherited. In `cmd` mode the `WINEPREFIX` is derived from the
   same home.
5. **Cleans up.** The NTFS mount lives under `/tmp/ved-windows.XXXXXX`. The
   mount, helper scripts and history file are removed on exit; use `--keep-temp`
   if you want to inspect them.

### Verifying the PowerShell environment

If the prompt behaves strangely, run these two lines in the `PS C:\>` prompt:

```powershell
$env:HOME
(Get-PSReadLineOption).HistorySavePath
```

You should see your normal home (for example `/home/<user>`) and a path under
`/tmp/ved-shell.XXXXXX/PSReadLine_history.txt`. Seeing `/root` means an older
`ved` version or a wrapper changed the environment; re-run with `-v` and check
the `shell environment: user=... home=...` debug line.

### Limitations — please read

- This is **not** your installed Windows. Its own `System32\cmd.exe`,
  `powershell.exe`, drivers, services and registry are not used. `pwsh` is the
  cross-platform PowerShell 7 runtime, and `cmd` is Wine's implementation.
- Windows PowerShell **5.1** cannot run under Wine; use PowerShell 7 (`pwsh`) or
  Wine's `cmd` instead.
- Read-only is the default on purpose. Most inspection and repair tasks work
  fine read-only; enable `--windows-write` only when you know the volume is not
  hibernated and you really want to change files. Linux NTFS mounts do not
  reproduce Windows ACL semantics exactly, so be careful with permissions.
- **BitLocker**: encrypted partitions must be unlocked first (for example with
  `dislocker`), then pass the unlocked device with `--partition`.
- `wine` cannot run as root. Start `ved` through `sudo` from your normal user
  account for `--shell cmd`. `pwsh` can run either as that user or directly as
  root.
- **`pwsh` is never installed automatically.** See
  [Installing pwsh](#installing-pwsh); if it is missing, `ved` prints the steps
  instead of letting a package transaction fail.

## Interactive flow

```
Available disks:
  1) /dev/nvme0n1  ...
Which disk do you want to use? [1]:

What do you want to do?
  1) Start it as a virtual machine (QEMU/KVM)
  2) Enter an installed Linux system (chroot)
  3) Run an installed Linux system as a container (systemd-nspawn)
  4) Open PowerShell or cmd on a Windows partition (no VM)
Option [1]:

Which Windows shell do you want?
  1) PowerShell 7 (native pwsh, no VM)
  2) cmd (Wine compatibility layer, no VM)
Option [1]:

What do you want to launch inside the system?
  1) An interactive shell
  2) A single graphical application
  3) A full desktop session
  4) Boot the whole system (init/systemd)
Option [1]:

Where should the graphical session be shown?
  1) On the current desktop (host screen)
  2) In a separate nested window (Xephyr)
Option [1]:
```

The shell question only appears for the Windows backend; the session/GUI questions
only appear for chroot/nspawn. The last question is skipped automatically when the
installed desktop cannot run inside Xephyr (see [GNOME 49+](#gnome-49-and-newer)).

## USB devices (webcam, Bluetooth/AirPods, phones)

By default (`--usb-auto auto`) `ved` scans the USB bus and:

- **Webcams** (USB video class) are passed to the VM automatically.
- **Bluetooth adapters** are passed with `guest-reset=true,guest-resets-all=true`,
  and shortly after boot the host toggles the adapter's `authorized` flag `0 → 1`
  to recover it. This is what lets **wireless earbuds such as AirPods** work inside
  the guest.
- **Android phones** (known vendors or MTP interface) are detected and you are asked
  whether to pass them.

Control the behavior with:

| Option | Effect |
| --- | --- |
| `--usb-auto auto` | Pass webcam + Bluetooth, offer phones (default). |
| `--usb-auto all` | Also pass detected phones without asking. |
| `--usb-auto none` / `--no-usb` | Disable USB auto-detection. |
| `--usb VID:PID` | Pass a specific device (repeatable). |
| `--reset-bluetooth VID:PID` | Reset a device shortly after the VM starts (repeatable). |

The network is provided by an emulated `e1000e` NIC (`--network user`), which avoids
flaky vendor Wi-Fi/Bluetooth drivers inside the guest.

## Display and OpenGL

Display modes: `auto`, `spice-gl`, `spice`, `gtk-gl`, `gtk`, `sdl`, `vnc`, `none`.

In `auto` mode, `ved` prefers a GPU-accelerated SPICE/GTK window and falls back
gracefully if the viewer or render node is unavailable. Force options with
`--gl` / `--no-gl` and `--render-node /dev/dri/renderDXXX`. When OpenGL is active,
`ved` reports the render node in use.

## TPM and Secure Boot

- `--tpm` / `--no-tpm`: hardware TPM passthrough when `/dev/tpm0` or `/dev/tpmrm0`
  exists, otherwise a software TPM via `swtpm`.
- `--secure-boot`: selects the Secure Boot OVMF firmware.

## Languages

The interface ships in **English** and **Spanish**. Choose explicitly with
`--lang en` / `--lang es` (`-L`), otherwise it follows your locale. Adding a language
is a matter of copying `locale/en.sh` and translating the values.

## Graphical desktop sessions (chroot / nspawn)

With `--graphical` (or `--session desktop` in the menu) you can launch a **full
desktop environment** from an installed system:

```bash
# chroot backend (lightweight, no PID 1 isolation)
./ved --backend chroot --partition /dev/nvme0n1p2 --graphical --session desktop

# nspawn backend (container; no systemd user session unless --boot is used)
./ved --backend nspawn --partition /dev/nvme0n1p2 --graphical --session desktop
```

What gets bound automatically:

| Resource | chroot | nspawn |
| --- | --- | --- |
| X11 socket (`/tmp/.X11-unix`, read-write) | ✓ | ✓ |
| Wayland socket (exported into the private runtime dir) | ✓ | ✓ |
| GPU/DRM (`/dev/dri`, read-write) | ✓ | ✓ |
| Audio (`/dev/snd`, PipeWire/Pulse) | ✓ | ✓ |
| Input devices (`/dev/input`) | ✓ | ✓ |
| System D-Bus | ✓ (private guest bus) | ✓ (private bus for graphical sessions, host bus otherwise) |
| Session D-Bus | ✓ (`dbus-run-session`) | ✓ (`dbus-run-session`) |
| Private user runtime dir (`/run/user/$UID`) | ✓ | ✓ |
| Xauthority | ✓ | ✓ |

The guest gets its **own private `XDG_RUNTIME_DIR`**, owned by the graphical user.
Only the host sockets it actually needs are exported into it (the Wayland
compositor socket for the `host` target, plus the PulseAudio/PipeWire audio
sockets). The host's `/run/user/$UID` is never bind-mounted as a whole: sharing it
would make the guest's systemd, keyring, gvfs, Remmina and D-Bus daemons collide
with the host's live sockets.

The session is wrapped with `dbus-run-session` so GNOME/KDE can start their
required services (gvfs, keyring, etc.). `systemd-run --user` is used only when a
systemd *user* manager is actually running inside the container; a container
started without `--boot` has no PID 1 and therefore no user manager, so the host's
systemd socket must not be used.

For graphical `chroot` and `systemd-nspawn` sessions, `ved` also isolates the
session identity:

- it creates a UTS namespace with `unshare --uts` and sets the hostname from the
  guest's `/etc/hostname` (for example `bbm-Precision-5770`) before entering the
  chroot;
- it sets `XDG_SESSION_DESKTOP` and `XDG_CURRENT_DESKTOP` from the selected
  session's `DesktopNames` instead of copying the host's values. This is what
  lets applications such as MSEdge see the installed desktop rather than the
  host session;
- it starts the **guest's own** system D-Bus in a private `/run/dbus` instead of
  bind-mounting the host bus. Otherwise `hostnamectl` and D-Bus-aware
  applications would still report the host name even with an isolated UTS
  namespace;
- small `org.freedesktop.login1` and `org.gnome.DisplayManager` stubs are
  registered on that private bus. Neither a chroot nor a non-boot `nspawn`
  container has `systemd-logind` or GDM, so GNOME 49 otherwise fails while
  starting its system-actions state machine with `StartServiceByName ...
  login1`, then logs a GDM registration error;
- graphical sessions raise `RLIMIT_MEMLOCK` when the caller has
  `CAP_SYS_RESOURCE`. For `systemd-nspawn`, `ved` also passes
  `--rlimit=MEMLOCK=infinity`, which sets the limit directly on the container
  payload;
- the guest's `/etc/gcrypt/fips_enabled` force switch is masked with a read-only
  `/dev/null` bind during graphical sessions. libgcrypt otherwise refuses to use
  its unlocked secure-memory fallback in FIPS mode, and GNOME Keyring aborts with
  `out of core in secure memory` when `mlock()` cannot be satisfied. The guest's
  original file is restored when the session ends.

For `systemd-nspawn`, the private bus directory is also passed as
`--bind=...:/run/dbus`. nspawn mounts its own tmpfs on `/run` after the setup
mounts, so binding the directory only on the host root directory is not enough;
GNOME Shell would still report `Could not connect to system bus`.

If `unshare --uts` or the guest's `dbus-daemon` / `dbus-broker-launch` is
unavailable, `ved` warns and continues instead of refusing to start the desktop.

The system root is mounted **before** the graphical questions are asked, so `ved`
can inspect the installed desktop and offer only the options that will work.

**GUI target** (`--gui` / `--gui-target`):

- `host` (default): render on your current Wayland/X11 session. GPU acceleration is
  available.
- `nested`: start a nested Xephyr X server (isolated window). Xephyr has no DRI3,
  so the session is forced to software rendering (`LIBGL_ALWAYS_SOFTWARE=1`);
  GPU acceleration is only available with the `host` target. Only valid for
  desktops that still support X11 sessions.

The list of installed sessions is filtered by the selected target: Xephyr only
offers X11 sessions, a Wayland session needs a host compositor socket, and
GNOME ≥ 49 never offers its leftover `gnome-xorg.desktop` entry.

### GNOME 49 and newer

GNOME Shell 49 (for example Ubuntu 25.10) no longer supports X11 sessions. Running
`gnome-session` inside Xephyr starts the background services (Remmina, Evolution,
gvfs, …) but never starts the shell, which shows up as a permanent black screen.
Leftover `*-xorg.desktop` entries under `/usr/share/xsessions` do not change that.

When ved detects GNOME ≥ 49 in a `desktop` session it:

1. forces the `host` target (and skips the Xephyr question);
2. starts the shell directly as a nested Wayland window on your desktop:

   ```bash
   dbus-run-session -- gnome-shell --devkit --wayland --wayland-display ved-$$
   ```

3. warns if the guest has no `mutter-devkit` instead of leaving you with a black
   screen.

Trade-offs: this path does not go through `gnome-session`, so autostart
applications are not launched. That is usually desirable for a rescue/inspection
desktop. Passing your own command (`--command`) disables the automatic selection.

> **Status:** the chroot backend has been tested with Ubuntu 25.10 (GNOME 49)
> guests. The nspawn path uses the same command and the bindings listed above; it
> is considered experimental for GNOME 49+.

## nspawn status bar (Ctrl+A prefix)

When using `--backend nspawn --boot` (or selecting "Boot the whole system" in the
menu), a **persistent status bar** appears at the bottom of your terminal:

```
 Machine: ved-nvme0n1p2-12345  PID: 67890  Ctrl+A then: [S]top [R]eboot [P]oweroff [Q]uit ved
```

- **Normal typing** passes through to the container (no key conflicts)
- **Ctrl+A** enters *command mode* — the bar changes to show available actions
- In command mode: **S** = terminate, **R** = reboot, **P** = poweroff, **Q** = quit ved
- **Esc / Ctrl+C / Ctrl+A** cancels command mode

This works like tmux's prefix key or vi's command mode — accessible, no accidental
keypresses, and you never need another terminal to manage the container.

## Options

```
Common options:
  -b, --backend NAME    qemu, chroot, nspawn or powershell (default: qemu)
  -L, --lang CODE       Language code: en, es (default: from the environment)
  -d, --disk DEVICE     Physical disk, for example /dev/nvme0n1
  -i, --image FILE      Disk image file (QEMU backend)
  -p, --partition DEV   Linux root partition (chroot/nspawn) or Windows partition
      --root-partition DEV
                        Alias for --partition
      --esp DEVICE      EFI system partition (auto-detected by default)
      --os TYPE         auto, linux or windows (default: auto)
      --efi-loader PATH EFI loader relative to the ESP (no `..`), or empty for the UEFI menu
      --storage MODE    temp or persistent (default: ask)
      --ram SIZE        Positive memory size, for example 8G or 8192M
      --cpus N          Number of virtual CPUs
      --accel MODE      auto, kvm or tcg (default: auto)
      --tpm             Enable TPM passthrough or a software TPM
      --no-tpm          Disable the TPM
      --secure-boot     Use the Secure Boot OVMF/AAVMF firmware
      --no-secure-boot  Disable Secure Boot
      --boot-menu       Show the QEMU boot menu (default)
      --no-boot-menu    Hide the QEMU boot menu
      --network MODE    user or none (default: user)
      --usb VID:PID     Pass a USB device to the VM; can be repeated
      --usb-auto MODE   auto, all or none (default: auto)
      --no-usb          Do not auto-detect USB devices
      --reset-bluetooth VID:PID
                        Reset a USB device shortly after the VM starts
      --display MODE    auto, spice-gl, spice, gtk-gl, gtk, sdl, vnc or none
      --gl              Force OpenGL acceleration
      --no-gl           Disable OpenGL acceleration
      --render-node DEV Force a DRM render node, for example /dev/dri/renderD128
      --user NAME       User to use inside a chroot or nspawn container
  -c, --command CMD     Command to run in the chroot, nspawn or powershell backend
      --shell NAME      powershell backend: pwsh or cmd (default: pwsh)
      --windows-write   Mount the Windows partition read-write (default: read-only)
      --windows-ro      Force read-only (useful to override a config file)
      --windows-drive L Drive letter for the partition in pwsh (default: C)
      --graphical       Bind the host display and audio into chroot/nspawn
      --boot            Boot the guest with systemd-nspawn instead of a command
      --session MODE    shell, app, desktop or system (default: ask)
      --app CMD         Run one graphical application (implies --session app)
      --gui TARGET      Host or nested Xephyr display: host or nested (default: ask)
      --gui-target TARGET
                        Alias for --gui
      --nested          Shortcut for --gui nested
      --host-display    Shortcut for --gui host
      --arch ARCH       QEMU guest architecture: auto, x86_64 or aarch64

Other options:
      --config FILE     Load a configuration file before applying options (trusted Bash code)
      --no-install      Do not install missing packages
  -y, --yes             Answer yes to confirmation prompts
  -n, --dry-run         Print the command instead of running it
      --keep-temp       Keep temporary files after exit
  -v, --verbose         Show debugging output
  -h, --help            Show this help
  -V, --version         Show the version
```

> **Configuration security:** `--config` sources the file as Bash, including after
> privilege escalation. Only load configuration files you control and trust.

## Examples

```bash
# Interactive menu
./ved

# Boot a physical disk as a VM with 16 GB of RAM and 10 CPUs
./ved --disk /dev/nvme0n1 --ram 16G --cpus 10

# Boot a Windows disk with TPM and Secure Boot
./ved --disk /dev/nvme0n1 --os windows --tpm --secure-boot

# Boot a disk image, force software rendering
./ved --image ~/win11.qcow2 --no-gl

# Print the QEMU command without running it
./ved --disk /dev/nvme0n1 --dry-run

# Enter an installed Linux system with chroot, sharing the host display
./ved --backend chroot --partition /dev/nvme0n1p2 --graphical

# Launch a full desktop from an installed system (chroot).
# GNOME 49+ is detected automatically and started with gnome-shell --devkit.
./ved --backend chroot --partition /dev/nvme0n1p2 --graphical --session desktop

# Same with nspawn (experimental for GNOME 49+)
./ved --backend nspawn --partition /dev/nvme0n1p2 --graphical --session desktop

# Inspect the exact command that would be used for a desktop session
./ved --backend chroot --partition /dev/nvme0n1p2 --graphical --session desktop --dry-run

# Boot a Linux install as a container with systemd (status bar with Ctrl+A)
./ved --backend nspawn --partition /dev/nvme0n1p2 --boot

# Run a single graphical app (e.g. Firefox) from an installed system
./ved --backend nspawn --partition /dev/nvme0n1p2 --graphical --session app --command firefox

# Force a specific desktop command instead of the automatic selection
./ved --backend chroot --partition /dev/nvme0n1p2 --graphical --session desktop \
  --command 'dbus-run-session -- gnome-shell --devkit --wayland --wayland-display ved-0'

# Pass a specific USB device and reset the Bluetooth adapter
./ved --disk /dev/nvme0n1 --usb 413c:301a --reset-bluetooth 8087:0033

# Open PowerShell 7 on a Windows partition (no QEMU VM)
./ved --backend powershell --disk /dev/nvme0n1

# Same, but with Wine cmd and an explicit partition
./ved -b powershell -p /dev/nvme0n1p3 --shell cmd

# Force read-only and use D: instead of C:
./ved -b powershell -p /dev/nvme0n1p3 --windows-ro --windows-drive D

# Run one PowerShell command against the Windows partition
./ved -b powershell -p /dev/nvme0n1p3 -c 'Get-ChildItem C:\'
```

## Project layout

```
ved                     single entry point
lib/
  core.sh               globals, CLI parsing, privilege handling, dispatch
  i18n.sh               locale loading and message helpers
  platform.sh           distribution detection and dependency installation
  ui.sh                 menus, prompts, configuration summary
  disks.sh              disk/partition/EFI-loader/guest-OS detection
  firmware.sh           OVMF, TPM, audio, render nodes, USB detection
  display.sh            display mode selection and viewer launch
  session.sh            guest desktop probing and session setup
  backends/
    qemu.sh             QEMU/KVM backend
    chroot.sh           chroot backend
    nspawn.sh           systemd-nspawn backend
    powershell.sh       Windows-partition shell backend (pwsh / Wine cmd)
locale/
  en.sh                 English messages
  es.sh                 Spanish messages
tests/
  cli_test.sh           non-privileged CLI regression tests
.github/workflows/
  ci.yml                GitHub Actions validation workflow
```

## Development and testing

The automated checks are deliberately safe: they never mount devices, call
`sudo`, start QEMU, open `pwsh`/Wine, or touch installed systems. They run as a
normal user, use a private temporary directory, and stub external tools such as
`lsblk`, `have` and `t` where needed.

Run them from the repository root:

```bash
make syntax  # bash -n on ved, lib/*.sh, locale/*.sh
make test    # non-privileged CLI regression tests
make lint    # ShellCheck (skipped with a warning if not installed)
make check   # syntax + test + lint; this is the default target
```

Each check prints `ok - <name>`; a failure prints `not ok - <name>` and makes the
suite exit non-zero. GitHub Actions runs `make check` on every push and pull
request (`.github/workflows/ci.yml`) and installs ShellCheck on the runner.

### What the suite covers

- **CLI parsing and validation**: version/help, backend and shell aliases,
  invalid options, drive-letter validation, EFI loader traversal, RAM format.
- **Option normalization**: case-insensitive backends/shells, `--windows-write`
  and `--windows-ro` precedence, lowercase drive letters uppercased.
- **Locale loading**: English and Spanish contain the Windows backend keys, and
  missing keys fall back to the key name rather than crashing.
- **Runtime directories**: each run gets an isolated directory and cleanup
  removes it.
- **Windows backend helpers**:
  - mount options with and without a graphical user;
  - NTFS/BitLocker candidate detection and already-mounted partition reuse;
  - hibernation detection via `hiberfil.sys`;
  - generated `C:` PSDrive script, private PSReadLine history path, and the
    absence of root-only `/run/ved` paths in generated scripts;
  - clean `runuser` environment for both `pwsh` and Wine: `HOME`, `USER`,
    `LOGNAME` and `XDG_*` come from `passwd`, never from root;
  - dry-run construction of the interactive, one-shot and `cmd` commands;
  - distribution-specific PowerShell install hints.

### Adding a test

For a CLI-level check, add one line next to the other `run_ved` calls:

```bash
run_ved my_new_check 1 'Expected error text' --backend powershell --shell fish
```

For internal helpers, add a function that runs in a subshell, source only the
modules it needs, stub external commands, and call `pass`/`fail` explicitly:

```bash
run_my_helper() (
    # shellcheck source=../lib/core.sh
    source "$PROJECT_ROOT/lib/core.sh"
    t() { printf '%s' "$1"; }
    local value
    value="$(my_helper)"
    [[ "$value" == "expected" ]]
)
```

Keep tests non-privileged. Put scratch files under `$TMPDIR_TEST` (removed by
the `EXIT` trap), and never hardcode a username, UID or real device path.

### Manual smoke tests

These need real hardware and are intentionally **not** part of `make test`:

```bash
# Print the exact mount and pwsh command without touching the partition
./ved -b powershell -d /dev/nvme0n1 --dry-run

# Open native PowerShell on the detected Windows partition (read-only)
./ved -b powershell -d /dev/nvme0n1

# Same with Wine cmd
./ved -b powershell -p /dev/nvme0n1p3 --shell cmd
```

In the resulting `PS C:\>` prompt, confirm the environment with
`$env:HOME` and `(Get-PSReadLineOption).HistorySavePath` as described in
[Verifying the PowerShell environment](#verifying-the-powershell-environment).

## Troubleshooting

- **"Hardware virtualization is not available"** — enable VT-x/AMD-V in your BIOS/UEFI
  (`/dev/kvm` must exist). Without it `ved` uses TCG, which is very slow.
- **No SPICE viewer found** — install `virt-viewer` (or use `spicy`), or use
  `--display none` for a headless run.
- **OpenGL context errors** — try `--no-gl`, or force a specific GPU with
  `--render-node /dev/dri/renderD128`.
- **Bluetooth disappears after the VM exits** — `ved` resets the adapter
  automatically; if it is still missing, re-run or pass `--reset-bluetooth VID:PID`.
- **Run `./ved --dry-run …`** to inspect the exact command and diagnose flags.
- **Black screen with a nested Xephyr window and GNOME 49+ (Ubuntu 25.10+)** —
  GNOME Shell 49 no longer supports X11, so `gnome-session` in Xephyr starts
  services but no shell. ved detects this and uses `gnome-shell --devkit` on the
  host display. The guest needs `mutter-devkit` (Ubuntu: `mutter-dev-bin`). Check
  the guest's GNOME version with `chroot <root> gnome-shell --version`.
- **`GNOME 49+ needs mutter-devkit in the guest`** — install the package that
  provides `/usr/libexec/mutter-devkit` in the installed system (Ubuntu:
  `mutter-dev-bin`; `dpkg -S /usr/libexec/mutter-devkit` tells you which one).
- **`Failed to start X Wayland: Directory "/tmp/.X11-unix" is not writable`**
  (nspawn) — the X11 socket directory must be bound read-write; the shell creates
  its own Xwayland socket there. ved binds it read-write.
- **`Created surfaceless renderer without GPU`** (nspawn) — `/dev/dri` was bound
  read-only or the container is not allowed to use the DRM devices. ved binds it
  read-write; if the GPU is still missing, bind the render node explicitly and
  allow it with `--property=DeviceAllow`.
- **`Couldn't connect to system bus` / `endSessionDialog.js` exception, then
  `could not connect to wayland server`** (nspawn) — the guest shell needs the
  system D-Bus (accounts service). Without `--boot` there is no system bus in the
  container, so ved binds the host's `/run/dbus`.
- **Mixed GNOME versions in the guest** (e.g. `gnome-shell 49~beta` with
  `mutter 49.0`) — happens on systems installed from a beta ISO and never fully
  upgraded. Run `apt full-upgrade` (or the equivalent) inside the installed system
  before reporting desktop problems.
- **GNOME/KDE falls back to "Something has gone wrong" screen** — ensure your user
  exists in the guest (UID 1000), use `--gui host`, or check `journalctl --user -f`
  inside the session for gnome-shell errors. For GNOME < 49, `--gui nested`
  (Xephyr) can help to isolate Wayland issues.
- **`Failed to connect to user scope bus via local transport: No data available`** —
  `systemd-run --user` was used in a container that was not booted with `--boot`.
  There is no systemd user manager inside it; `ved` falls back to
  `dbus-run-session`.
- **`DRI3 error` / `GL Helper exited with code 512` in Xephyr** — expected with a
  nested server. `ved` forces `LIBGL_ALWAYS_SOFTWARE=1` for the `nested` target.
  Use `--gui host` if you need GPU acceleration.
- **`ERROR: NVIDIA driver is not loaded`** — the guest ships NVIDIA userspace
  libraries but the NVIDIA devices are not available inside the chroot/container.
  Harmless; the session falls back to Mesa on the other GPU.
- **`couldn't connect to control socket ... /keyring/control` or
  `fuse: failed to access mountpoint .../gvfs`** — the guest was reusing the
  host's `/run/user/$UID`. `ved` creates a private runtime directory for the guest
  instead.
- **nspawn status bar not appearing** — requires a real TTY (`-t`); it won't show
  in scripts or pipes. Use `--dry-run` to verify the command.
- **`No NTFS or BitLocker partition was found`** (powershell backend) — pass the
  partition explicitly with `--partition`, or check that the device is really a
  Windows disk. BitLocker volumes must be unlocked first (for example with
  `dislocker`) and the unlocked mapper device passed with `--partition`.
- **`Neither ntfs-3g nor kernel ntfs3 support is available`** — install `ntfs-3g`.
- **`The Windows partition is hibernated`** — disable Windows Fast Startup
  (`powercfg /h off` in an elevated Windows prompt) before using
  `--windows-write`. The partition still works read-only.
- **`PowerShell 7 (pwsh) is not installed`** — see
  [Installing pwsh](#installing-pwsh). `ved` prints the same distro-specific
  steps and deliberately never auto-installs it. `--shell cmd` only needs
  `wine` from the standard repositories.
- **`The argument '.../ved-profile.ps1' is not recognized as the name of a script file`**
  — an older `ved` put the generated script in the root-only `/run/ved`
  directory. Current versions write it to a user-owned `/tmp/ved-shell.XXXXXX`
  directory; update `ved` if you still see this.
- **`Oops, something went wrong` / `System.IO.IOException: Permission denied`
  from PSReadLine** — check `$env:HOME` and
  `(Get-PSReadLineOption).HistorySavePath` in the prompt. They should show your
  normal home and a path under `/tmp/ved-shell.XXXXXX`. Current versions pass a
  clean environment to `runuser` and use a private history file. If you still
  see `/root`, run `ved -v` and include the `shell environment: user=... home=...`
  debug line when reporting it.
- **`Wine cannot run as root`** — run `ved` through `sudo` from your normal user
  account, or use `--shell pwsh`, which can also run directly as root.

## License

This project is released under the **GNU General Public License v3.0** (GPLv3).
See the full text at <https://www.gnu.org/licenses/gpl-3.0.html>.

You are free to use, study, share and improve it; derivative works must remain under
the same license, keeping these community freedoms for everyone.

---

Made by [@bitstuffing](https://github.com/bitstuffing) with love.
