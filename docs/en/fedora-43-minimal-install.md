# Fedora 43 — Minimal Custom Install

> **Status: skeleton.** This guide is being written. Sections marked TODO need real content.

This guide walks you through installing Fedora 43 in a minimal, custom configuration suitable for use as a dedicated audiophile playback host. It is the **pre-requisite** for running `setup.sh`.

The goal is a system with **only the packages you need**, no desktop environment, no audio servers (PulseAudio / PipeWire), no unnecessary background services. Every removed package is one less source of jitter and one less attack surface.

## 1. BIOS settings (before booting the installer)

These BIOS choices matter — some of them can't be changed once the OS is running.

- **Secure Boot: OFF** — required, the vanilla kernels can't be signed.
- **Hyper-Threading / SMT: ON or OFF?** — leave ON for now. The installer can disable it at runtime per zone. Disabling at BIOS level is fine if you never want it.
- **Virtualization (VT-x / AMD-V): OFF** — not needed for playback, reduces background activity.
- **CPU C-states: OFF (or "C0/C1 only")** — prevents the CPU from entering deep sleep that adds latency.
- **CPU P-states / SpeedStep / Cool'n'Quiet: OFF** — keep the CPU at max frequency.
- **Turbo Boost: your choice** — some prefer it OFF for predictable frequency; OS-level `no_turbo` does the same later.
- **Audio hardware (motherboard audio chip): DISABLE** if you never use it (you stream over the network, not via local DAC).
- **Wake-on-LAN / IPMI / management interfaces: OFF** unless needed.

TODO: add screenshots of common BIOS interfaces (AMI, Insyde, ASRock, etc.).

## 2. Choose the right Fedora ISO

You want the **Fedora 43 Everything netinstall** ISO, NOT the Workstation or Server live image:

- **Workstation** ships GNOME and a desktop stack you'd have to remove afterwards.
- **Server** ships a slightly less bloated stack, but still more than we want.
- **Everything netinstall** lets you pick exactly which package groups to install. This is what we want.

Download: https://alt.fedoraproject.org/

TODO: paste exact filename pattern for Fedora 43.

Write the ISO to a USB stick:

```bash
sudo dd if=Fedora-Everything-netinst-x86_64-43-*.iso of=/dev/sdX bs=4M status=progress conv=fdatasync
```

(Replace `/dev/sdX` with your USB device. Don't get this wrong — it will wipe whatever you point at.)

## 3. Custom partitioning

TODO: explain proposed partitioning scheme. Suggested baseline:

- `/boot/efi` — 512 MB FAT32 (or what Anaconda proposes)
- `/boot` — 1 GB ext4
- `/` (root) — 30-50 GB ext4 (xfs is fine too)
- `swap` — minimal or **none** (we disable swap anyway in `09-swap-disable.sh`)
- `/var` — optional separate partition if you want to isolate logs/db
- `/home` — minimal or skipped, you won't be storing user data here

The installer will move `/var/log` and `/var/tmp` to tmpfs as part of [`04-tmpfs-disk.sh`](../../modules/), so don't over-allocate `/var`.

## 4. Package group selection

In the Anaconda installer's **"Software Selection"** step, choose **"Minimal Install"** as the base environment, and uncheck every add-on.

We will install everything else we need (kernel-rt, FFmpeg, libupnp, ethtool, …) via the wizard.

TODO: list explicit `dnf groupinstall` equivalent for users who want to reproduce.

## 5. Network configuration during install

Do **not** enable a hostname-bound or zone-restricted network just yet. The installer can handle this later with `systemd-networkd`. Pick basic DHCP, validate the connection, and that's enough.

TODO: notes on multi-NIC setups (separate WAN-side and Diretta-target-side NICs).

## 6. After first boot — before running the wizard

```bash
sudo dnf -y update
sudo dnf -y install git
git clone https://github.com/cometdom/fedora-audiophile-setup.git
cd fedora-audiophile-setup
sudo ./setup.sh
```

Or run with `--dry-run` first if you want to preview every action:

```bash
sudo ./setup.sh --dry-run
```

---

TODO: add a troubleshooting section (Secure Boot off doesn't take effect, network not detected, etc.).
