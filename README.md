# fedora-audiophile-setup

Turn a clean **Fedora 43 or 44 minimal** install into a tuned audiophile playback host, ready to run [DirettaRendererUPnP](https://github.com/cometdom/DirettaRendererUPnP) and/or [slim2Diretta](https://github.com/cometdom/slim2Diretta).

> **Status: 1.0.** All modules implemented and tested on Fedora 43 and 44 (x86_64). Production-ready for the supported scope.

## What it does

An interactive Bash wizard that, in a single run, applies all the system-level tuning that has been documented and battle-tested for low-latency network audio playback on Linux:

- Installs the **PREEMPT_RT kernel** from the official Fedora [`@kernel-vanilla/stable` COPR](https://fedoraproject.org/wiki/Kernel_Vanilla_Repositories) and sets it as the default boot entry (RT-ness verified by content before switching the default)
- Configures kernel cmdline for **CPU isolation** (`isolcpus`, `nohz_full`, `rcu_nocbs`, `irqaffinity`, optional `nosmt`)
- Lets you **keep NetworkManager (tuned)** or **switch to systemd-networkd** — your call. The default keeps NM (safer on SSH-only hosts, `nmtui` available); networkd is opt-in for the most deterministic stack.
- Sets the CPU governor to **performance**, disables C-states, no_turbo
- Pins NIC IRQs and audio threads to dedicated cores via the [DRUP tuner scripts](https://github.com/cometdom/DirettaRendererUPnP/blob/main/diretta-renderer-tuner.sh)
- Configures **MTU (up to 16128)** and ethtool link tuning on the Diretta NIC (during the DRUP / slim2Diretta install steps, where the right NIC is known)
- Moves `journald` to RAM and optionally `/var/log` + `/var/tmp` to tmpfs (reduces disk activity during playback)
- Disables `swap`, sets `vm.swappiness=0`
- Disables unneeded services (bluetooth, cups, etc.)
- Applies a `tuned` profile geared for latency
- Optionally installs and configures DirettaRendererUPnP and/or slim2Diretta

After a single reboot, your audio host is fully tuned and ready.

## Requirements

- **Fedora 43 or 44** (Server or Workstation, minimal install — see [the install guide](docs/en/fedora-43-minimal-install.md)). Fedora 44 is what `fedoraproject.org` promotes right now; Fedora 43 is still supported until ~end of 2026.
- **Secure Boot disabled** in BIOS (the vanilla kernels can't be signed)
- Root access
- Internet connection (to fetch the kernel COPR and dependencies)
- A handful of host packages installed before running the wizard:

  ```bash
  sudo dnf -y install git curl mokutil grubby dnf-plugins-core tar
  ```

  `git` lets you clone this repo; `tar` extracts the Diretta SDK archive (no longer bundled in the Fedora 44 custom base); the others are used by the wizard itself (`curl` to fetch upstream scripts, `mokutil` to verify Secure Boot is off, `grubby` to set the kernel-rt as the default boot entry, `dnf-plugins-core` for `dnf copr enable`). All are tiny and idempotent — `dnf` will skip what's already present.

## Quick start

```bash
git clone https://github.com/cometdom/fedora-audiophile-setup.git
cd fedora-audiophile-setup
sudo ./setup.sh
```

The wizard opens with an **interactive numbered menu** :

```
What do you want to do?

   1) Full install              all modules in order (recommended)
   2) 00 preflight            — verify Fedora 43 / x86_64 / Secure Boot OFF / IPv6
   3) 01 kernel-rt            — install the PREEMPT_RT kernel...
   ...
  14) 99 finalize             — sanity check + offer reboot
  15) Exit

Choose [1]:
```

Press Enter (or `1`) for the full install. Any other number runs that single module standalone. The two-digit prefix shown next to each name (`00`, `01`, …, `99`) is the module number — that's the same `NN` you'll see in the file names (`modules/NN-name.sh`) and in the documentation; the leading number (`2)`, `3)`, …) is the menu choice. They differ because the menu has extra entries (Full install, Exit) that aren't modules.

Use `--dry-run` to preview every action without applying changes — works with both the menu and `--only`:

```bash
sudo ./setup.sh --dry-run
```

Power-user shortcut: skip the menu and re-run a single module by name:

```bash
sudo ./setup.sh --only kernel-rt
```

## Documentation

- **[Newbie walkthrough](docs/en/newbie-walkthrough.md)** — start here if you've never installed Linux. Goes from empty mini-PC to first listening test, no prior knowledge assumed. (**Français :** [guide pas à pas pour débutant](docs/fr/newbie-walkthrough.md))
- [Fedora 43 minimal install (custom)](docs/en/fedora-43-minimal-install.md) — terser install reference.
- [Post-install tuning reference](docs/en/post-install-tuning.md) — what each module does, and why.
- [Diretta NIC toggle](docs/en/diretta-net-toggle.md) — companion tool (`scripts/diretta-net-toggle.sh`) to temporarily bridge the LAN and Diretta NICs so the target is reachable from the LAN (e.g. to check/update its firmware) without recabling, then switch back for listening. systemd-networkd only. (**Français :** [bascule NIC Diretta](docs/fr/diretta-net-toggle.md))

## Roadmap

### Released

- [x] **v1.0** — Working wizard with all modules, interactive menu, Fedora 43/44 support, EN docs + French newbie walkthrough, PDF generation
- [x] **v1.1** — Kernel selection hardening: vanilla `@kernel-vanilla/stable` PREEMPT_RT kernel only (CachyOS-RT dropped after no-boot reports), RPM `vmlinuz` content verification and `CONFIG_PREEMPT_RT` check before switching the default GRUB entry
- [x] **v1.2** — Universal Diretta MTU persistence via a systemd-udevd `.link` drop-in — works under **both** NetworkManager and systemd-networkd
- [x] **v1.3** — `diretta-net-toggle` companion tool: temporarily bridge LAN + Diretta NICs so the target is reachable from the LAN (firmware checks, etc.) without recabling, then switch back for listening
- [x] **v1.4** — Module 06 gains an opt-in CPU max-frequency cap (`/etc/default/audiophile-cpu-states`, re-tunable without re-running the wizard) and always-on memory/MM jitter reducers (THP, KSM, NUMA balancing); walkthrough recommends BIOS-side CPU Boost off + OS→BIOS consolidation path for the max-freq cap
- [x] **v1.5** — Stable interface naming by MAC (opt-in, default Y): NICs renamed to `eth-lan` / `eth-diretta` via udev `.link` drop-ins, surviving NIC swap, added PCIe card, and GPU insert/remove. Single canonical Diretta `.link` carrying rename + MTU + offload-off (gso/tso/gro/lro). `diretta-net-toggle` hardened with cache validation, actionable error messages when networkd is inactive, and a new `purge` subcommand for recovery from NetworkManager. Menu shows the module-file prefix (`NN`) next to each name

### Planned

- [ ] **v1.6+** — Spanish translation; finish translating the remaining guides to French
- [ ] Optional advanced path: compile the vanilla PREEMPT_RT kernel from source
- [ ] Optional config-file mode for unattended provisioning
- [ ] _separate sibling repo_ — Raspberry Pi 5 audiophile setup on **Fedora 44 ARM64** (vanilla PREEMPT_RT from the `@kernel-vanilla/stable` COPR — aarch64 builds confirmed working; 4-core isolation `isolcpus=1-3 nohz_full=1-3 rcu_nocbs=1-3 irqaffinity=0`; DRUP build target `aarch64-linux-15k16` for the Pi 5's 16 KiB pages)

## License

[MIT](LICENSE)

## Credits

This installer orchestrates and builds on the work of:

- [DirettaRendererUPnP](https://github.com/cometdom/DirettaRendererUPnP) by Dominique COMET (cometdom)
- [slim2Diretta](https://github.com/cometdom/slim2Diretta) by Dominique COMET (cometdom)
- The Fedora Kernel Vanilla repositories maintained by [Thorsten Leemhuis (knurd)](https://fedoraproject.org/wiki/Kernel_Vanilla_Repositories)
- All the testers and contributors of the Diretta audiophile community

### Raspberry Pi sibling testers

Early testers on the Audiophile Style forum who ran the [Raspberry Pi build](https://github.com/cometdom/fedora-rpi-audiophile-setup) on real Pi 4/5 hardware and reported precise bugs — several of which were shared with, and fixed in, this x86_64 codebase too (the RT-kernel default and Fedora's zram swap):

- **Auke** — Fedora `zram-generator` swap persistence (fixed here too), and the ARM tuner `pipefail` abort (with a `bash -x` trace and patches).
- **ditusade** — the RT kernel not being set as the default boot entry, the `+rt` vmlinuz mismatch (fixed here too); first end-to-end Pi 5 proof.
- **Progman** — first Pi 4 run; low-RAM FFmpeg 7.1 / no-LTO validation; full-install resilience.
