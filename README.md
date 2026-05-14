# fedora-audiophile-setup

Turn a clean **Fedora 43 minimal** install into a tuned audiophile playback host, ready to run [DirettaRendererUPnP](https://github.com/cometdom/DirettaRendererUPnP) and/or [slim2Diretta](https://github.com/cometdom/slim2Diretta).

> **Status: early development.** Scope and design are settled, modules are being implemented one by one. Not ready for production use yet.

## What it does

An interactive Bash wizard that, in a single run, applies all the system-level tuning that has been documented and battle-tested for low-latency network audio playback on Linux:

- Installs the **PREEMPT_RT kernel** from the official Fedora [`@kernel-vanilla/stable` COPR](https://fedoraproject.org/wiki/Kernel_Vanilla_Repositories)
- Configures kernel cmdline for **CPU isolation** (`isolcpus`, `nohz_full`, `rcu_nocbs`, `irqaffinity`, optional `nosmt`)
- Switches from NetworkManager to **systemd-networkd** (better for sustained streaming)
- Sets the CPU governor to **performance**, disables C-states, no_turbo
- Pins NIC IRQs and audio threads to dedicated cores via the [DRUP tuner scripts](https://github.com/cometdom/DirettaRendererUPnP/blob/main/diretta-renderer-tuner.sh)
- Configures **MTU 9000 (jumbo frames)** and ethtool link tuning
- Moves `journald` to RAM and optionally `/var/log` + `/var/tmp` to tmpfs (reduces disk activity during playback)
- Disables `swap`, sets `vm.swappiness=0`
- Disables unneeded services (bluetooth, cups, etc.)
- Applies a `tuned` profile geared for latency
- Optionally installs and configures DirettaRendererUPnP and/or slim2Diretta

After a single reboot, your audio host is fully tuned and ready.

## Requirements

- **Fedora 43** (Server or Workstation, minimal install — see [the install guide](docs/en/fedora-43-minimal-install.md))
- **Secure Boot disabled** in BIOS (the vanilla kernels can't be signed)
- Root access
- Internet connection (to fetch the kernel COPR and dependencies)

## Quick start

```bash
git clone https://github.com/cometdom/fedora-audiophile-setup.git
cd fedora-audiophile-setup
sudo ./setup.sh
```

The wizard will walk you through each step interactively. Use `--dry-run` to preview every action without applying changes:

```bash
sudo ./setup.sh --dry-run
```

To re-run a single module after initial setup:

```bash
sudo ./setup.sh --only kernel-rt
```

## Documentation

- [Fedora 43 minimal install (custom)](docs/en/fedora-43-minimal-install.md) — pre-requisite guide
- [Post-install tuning reference](docs/en/post-install-tuning.md) — what each module does, and why

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
