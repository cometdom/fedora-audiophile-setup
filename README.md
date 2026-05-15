# fedora-audiophile-setup

Turn a clean **Fedora 43 or 44 minimal** install into a tuned audiophile playback host, ready to run [DirettaRendererUPnP](https://github.com/cometdom/DirettaRendererUPnP) and/or [slim2Diretta](https://github.com/cometdom/slim2Diretta).

> **Status: early development.** Scope and design are settled, modules are being implemented one by one. Not ready for production use yet.

## What it does

An interactive Bash wizard that, in a single run, applies all the system-level tuning that has been documented and battle-tested for low-latency network audio playback on Linux:

- Installs the **PREEMPT_RT kernel** from the official Fedora [`@kernel-vanilla/stable` COPR](https://fedoraproject.org/wiki/Kernel_Vanilla_Repositories)
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
  sudo dnf -y install git curl mokutil grubby dnf-plugins-core
  ```

  `git` lets you clone this repo; the others are used by the wizard itself (`curl` to fetch upstream scripts, `mokutil` to verify Secure Boot is off, `grubby` to set the kernel-rt as the default boot entry, `dnf-plugins-core` for `dnf copr enable`). All are tiny and idempotent — `dnf` will skip what's already present.

## Quick start

```bash
git clone https://github.com/cometdom/fedora-audiophile-setup.git
cd fedora-audiophile-setup
sudo ./setup.sh
```

The wizard opens with an **interactive numbered menu** :

```
What do you want to do?

   1) Full install         all modules in order (recommended)
   2) preflight            — verify Fedora 43 / x86_64 / Secure Boot OFF / IPv6
   3) kernel-rt            — install the PREEMPT_RT kernel...
   ...
  14) finalize             — sanity check + offer reboot
  15) Exit

Choose [1]:
```

Press Enter (or `1`) for the full install. Any other number runs that single module standalone.

Use `--dry-run` to preview every action without applying changes — works with both the menu and `--only`:

```bash
sudo ./setup.sh --dry-run
```

Power-user shortcut: skip the menu and re-run a single module by name:

```bash
sudo ./setup.sh --only kernel-rt
```

## Documentation

- **[Newbie walkthrough](docs/en/newbie-walkthrough.md)** — start here if you've never installed Linux. Goes from empty mini-PC to first listening test, no prior knowledge assumed.
- [Fedora 43 minimal install (custom)](docs/en/fedora-43-minimal-install.md) — terser install reference.
- [Post-install tuning reference](docs/en/post-install-tuning.md) — what each module does, and why.

## Roadmap

- [ ] v0.1 — Working wizard with all modules, English docs only
- [ ] v0.2 — French and Spanish translations of the documentation
- [ ] v0.3 — Support advanced option: compile vanilla preempt-rt kernel from source
- [ ] v0.4 — Optional config-file mode for unattended provisioning

## License

[MIT](LICENSE)

## Credits

This installer orchestrates and builds on the work of:

- [DirettaRendererUPnP](https://github.com/cometdom/DirettaRendererUPnP) by Dominique COMET (cometdom)
- [slim2Diretta](https://github.com/cometdom/slim2Diretta) by Dominique COMET (cometdom)
- The Fedora Kernel Vanilla repositories maintained by [Thorsten Leemhuis (knurd)](https://fedoraproject.org/wiki/Kernel_Vanilla_Repositories)
- All the testers and contributors of the Diretta audiophile community
