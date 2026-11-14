# ved — Virtual External Devices

**Boot a physical disk, a partition or a disk image as a virtual machine, or enter an installed Linux system as a chroot / container — from one command.**

`ved` is a single, modular Bash tool that wraps QEMU/KVM, `chroot` and `systemd-nspawn`
behind a friendly, interactive menu. It auto-detects your disks, EFI loaders, GPUs,
TPM and USB devices, installs missing packages for your distribution, and asks for
the administrator password only once.

> It started as two personal scripts (`qemu-nobara.sh` and `qemu-ubuntu.sh`, kept in the
> repository for reference) and grew into one portable, translated tool.

---

## Table of contents

- [Features](#features)
- [Requirements](#requirements)
- [Supported distributions](#supported-distributions)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Backends](#backends)
- [Interactive flow](#interactive-flow)
- [USB devices (webcam, Bluetooth/AirPods, phones)](#usb-devices-webcam-bluetoothairpods-phones)
- [Display and OpenGL](#display-and-opengl)
- [TPM and Secure Boot](#tpm-and-secure-boot)
- [Languages](#languages)
- [Options](#options)
- [Examples](#examples)
- [Project layout](#project-layout)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## Features

- **One entry point**: `./ved`. Run it with no arguments for an interactive menu.
- **Physical disks, partitions or images**: pass a whole disk (`--disk`), a Linux root
  partition (`--partition`) or a disk image (`--image`).
- **Three backends**: QEMU/KVM, `chroot`, and `systemd-nspawn`.
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
- **Dry run** (`--dry-run`) to print the exact QEMU command without running it.
- **Administrator password asked once**, then re-executes through `sudo` cleanly.
- **Graphical desktop sessions** in chroot/nspawn: launch a full GNOME/KDE/Plasma/Xfce
  session with GPU acceleration, Wayland/X11, audio, and input devices.
- **nspawn status bar** (Ctrl+A prefix): when booting a full system with `--boot`,
  a persistent status bar shows machine name/PID and lets you Stop/Reboot/Poweroff/Quit
  without leaving the terminal.

## Requirements

- Linux with **Bash 4.3+**.
- **KVM** (`/dev/kvm`) for hardware acceleration — falls back to TCG (slow) if absent.
- A graphical session if you want a windowed VM (SPICE/GTK viewer).

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
2. ask what to do with it (virtual machine, chroot or container);
3. ask for the administrator password (once);
4. detect the EFI loader, guest OS, memory, CPUs and storage mode;
5. show a summary of exactly what it is about to launch, and start it.

## Backends

| Backend | Flag | What it does |
| --- | --- | --- |
| **QEMU/KVM** | `-b qemu` | Runs a physical disk, a partition or an image as a full virtual machine (UEFI + SPICE). |
| **chroot** | `-b chroot` | Mounts an installed Linux system and enters it with `chroot`. Can bind the host display/audio with `--graphical`. |
| **systemd-nspawn** | `-b nspawn` | Mounts an installed Linux system and runs it as a container; `--boot` boots it with systemd. |

## Interactive flow

```
Available disks:
  1) /dev/nvme0n1  ...
Which disk do you want to use? [1]:

What do you want to do?
  1) Start it as a virtual machine (QEMU/KVM)
  2) Enter an installed Linux system (chroot)
  3) Run an installed Linux system as a container (systemd-nspawn)
Option [1]:
```

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
desktop environment** (GNOME, KDE Plasma, Xfce, etc.) from an installed system:

```bash
# chroot backend (lightweight, no PID 1 isolation)
./ved --backend chroot --partition /dev/nvme0n1p2 --graphical --session desktop

# nspawn backend (better isolation, systemd user session)
./ved --backend nspawn --partition /dev/nvme0n1p2 --graphical --session desktop
```

What gets bound automatically:

| Resource | chroot | nspawn |
| --- | --- | --- |
| X11 socket (`/tmp/.X11-unix`) | ✓ | ✓ |
| Wayland socket (`$XDG_RUNTIME_DIR`) | ✓ | ✓ |
| GPU/DRM (`/dev/dri`) | ✓ | ✓ |
| Audio (`/dev/snd`, PipeWire/Pulse) | ✓ | ✓ |
| Input devices (`/dev/input`) | ✓ | ✓ |
| D-Bus session/user bus | ✓ | ✓ |
| User runtime dir (`/run/user/$UID`) | ✓ | ✓ |
| Xauthority | ✓ | ✓ |

The session is wrapped with `systemd-run --user` (preferred) or `dbus-run-session`
so GNOME/KDE can start their required services (gvfs, polkit, keyring, etc.).

**GUI target** (`--gui` / `--gui-target`):

- `host` (default): render on your current Wayland/X11 session
- `nested`: start a nested Xephyr X server (isolated window)

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
  -b, --backend NAME    qemu, chroot or nspawn (default: qemu)
  -L, --lang CODE       Language code: en, es (default: from the environment)
  -d, --disk DEVICE     Physical disk, for example /dev/nvme0n1
  -i, --image FILE      Disk image file (QEMU backend)
  -p, --partition DEV   Linux root partition (chroot/nspawn backend)
      --esp DEVICE      EFI system partition (auto-detected by default)
      --os TYPE         auto, linux or windows (default: auto)
      --efi-loader PATH EFI loader relative to the ESP, or empty for the UEFI menu
      --storage MODE    temp or persistent (default: ask)
      --ram SIZE        Memory size, for example 8G or 8192M
      --cpus N          Number of virtual CPUs
      --accel MODE      auto, kvm or tcg (default: auto)
      --tpm             Enable TPM passthrough or a software TPM
      --no-tpm          Disable the TPM
      --secure-boot     Use the Secure Boot OVMF firmware
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
  -c, --command CMD     Command to run in the chroot or nspawn backend
      --graphical       Bind the host display and audio into chroot/nspawn
      --boot            Boot the guest with systemd-nspawn instead of a command

Other options:
      --config FILE     Load a configuration file before applying options
      --no-install      Do not install missing packages
  -y, --yes             Answer yes to confirmation prompts
  -n, --dry-run         Print the QEMU command instead of running it
      --keep-temp       Keep temporary files after exit
  -v, --verbose         Show debugging output
  -h, --help            Show this help
  -V, --version         Show the version
```

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

# Launch a full GNOME/KDE/Xfce desktop from an installed system (chroot)
./ved --backend chroot --partition /dev/nvme0n1p2 --graphical --session desktop

# Launch a full desktop with nspawn (better isolation, systemd user session)
./ved --backend nspawn --partition /dev/nvme0n1p2 --graphical --session desktop

# Boot a Linux install as a container with systemd (status bar with Ctrl+A)
./ved --backend nspawn --partition /dev/nvme0n1p2 --boot

# Run a single graphical app (e.g. Firefox) from an installed system
./ved --backend nspawn --partition /dev/nvme0n1p2 --graphical --session app --command firefox

# Pass a specific USB device and reset the Bluetooth adapter
./ved --disk /dev/nvme0n1 --usb 413c:301a --reset-bluetooth 8087:0033
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
  backends/
    qemu.sh             QEMU/KVM backend
    chroot.sh           chroot backend
    nspawn.sh           systemd-nspawn backend
locale/
  en.sh                 English messages
  es.sh                 Spanish messages
qemu-nobara.sh          original reference script (kept for history)
qemu-ubuntu.sh          original reference script (kept for history)
```

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
- **GNOME/KDE falls back to "Something has gone wrong" screen** — ensure your user
  exists in the guest (UID 1000), try `--gui nested` (Xephyr) to isolate Wayland
  issues, or check `journalctl --user -f` inside the session for gnome-shell errors.
- **nspawn status bar not appearing** — requires a real TTY (`-t`); it won't show
  in scripts or pipes. Use `--dry-run` to verify the command.

## License

This project is released under the **GNU General Public License v3.0** (GPLv3).
See the full text at <https://www.gnu.org/licenses/gpl-3.0.html>.

You are free to use, study, share and improve it; derivative works must remain under
the same license, keeping these community freedoms for everyone.

---

Made by [@bitstuffing](https://github.com/bitstuffing) with love.
