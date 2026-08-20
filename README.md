# fedora-audiophile-setup

Turn a clean **Fedora 43 or 44 minimal** install into a tuned audiophile playback host, ready to run [DirettaRendererUPnP](https://github.com/cometdom/DirettaRendererUPnP) and/or [slim2Diretta](https://github.com/cometdom/slim2Diretta).

> 🆕 **First time installing Linux?** Read the step-by-step newbie walkthrough first — it takes you from empty mini-PC to first listening test, no prior knowledge assumed.
> Available in: **English** ([web](docs/en/newbie-walkthrough.md) · [PDF](https://github.com/cometdom/fedora-audiophile-setup/releases/latest/download/newbie-walkthrough-en.pdf)) · **Français** ([web](docs/fr/newbie-walkthrough.md) · [PDF](https://github.com/cometdom/fedora-audiophile-setup/releases/latest/download/newbie-walkthrough-fr.pdf))

> **Status: v2.4.4** — Production-ready on Fedora 43/44 (x86_64). All modules implemented and tested.

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
- Optionally installs and configures DirettaRendererUPnP, slim2Diretta and/or slim2UPnP (a Slimproto→UPnP bridge that pairs with DRUP for LMS)
- Optionally runs the **entire root filesystem from RAM** (module 13): full overlayfs mode via a custom dracut initramfs module (zero disk I/O during playback), or `systemd.volatile=state` for a lighter `/var`-only approach

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
  16) 99 finalize             — sanity check + offer reboot
  17) Exit

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

### Unattended mode

For scripted installs — a kickstart `%post`, CI, or fleet provisioning — the whole wizard can run without a TTY:

```bash
sudo ./setup.sh --unattended
sudo ./setup.sh --unattended --answers my-answers.env
```

Every prompt takes its default; an answers file overrides any of them through `UA_<KEY>` variables (one per prompt — the full list, with each prompt's default, is in [`extras/answers-example.env`](extras/answers-example.env)):

```bash
# my-answers.env — headless appliance: RAM mode on, no Diretta apps
UA_RAM_MODE_ACTION=e
UA_RAM_MODE_STRATEGY=V
UA_RAM_MODE_ENABLE=Y
UA_DRUP_INSTALL=N
UA_S2D_INSTALL=N
```

`--dry-run --unattended` previews the whole run, answers included. An invalid answer that a prompt loop keeps rejecting aborts the run (fail-fast) rather than looping forever.

## Documentation

- **[Newbie walkthrough](docs/en/newbie-walkthrough.md)** — start here if you've never installed Linux. Goes from empty mini-PC to first listening test, no prior knowledge assumed. (**Français :** [guide pas à pas pour débutant](docs/fr/newbie-walkthrough.md))
- [Fedora 43 minimal install (custom)](docs/en/fedora-43-minimal-install.md) — terser install reference.
- [Post-install tuning reference](docs/en/post-install-tuning.md) — what each module does, and why.
- [Diretta NIC toggle](docs/en/diretta-net-toggle.md) — companion tool (`scripts/diretta-net-toggle.sh`) to temporarily bridge the LAN and Diretta NICs so the target is reachable from the LAN (e.g. to check/update its firmware) without recabling, then switch back for listening. systemd-networkd only. (**Français :** [bascule NIC Diretta](docs/fr/diretta-net-toggle.md))
- [Unattended answers contract](docs/en/unattended-answers-contract.md) — the `UA_<KEY>` stability guarantee for anyone automating `setup.sh --unattended` (kickstart, CI, or a GUI/web frontend).

## Roadmap

### Released

- [x] **v1.0** — Working wizard with all modules, interactive menu, Fedora 43/44 support, EN docs + French newbie walkthrough, PDF generation
- [x] **v1.1** — Kernel selection hardening: vanilla `@kernel-vanilla/stable` PREEMPT_RT kernel only (CachyOS-RT dropped after no-boot reports), RPM `vmlinuz` content verification and `CONFIG_PREEMPT_RT` check before switching the default GRUB entry
- [x] **v1.2** — Universal Diretta MTU persistence via a systemd-udevd `.link` drop-in — works under **both** NetworkManager and systemd-networkd
- [x] **v1.3** — `diretta-net-toggle` companion tool: temporarily bridge LAN + Diretta NICs so the target is reachable from the LAN (firmware checks, etc.) without recabling, then switch back for listening
- [x] **v1.4** — Module 06 gains an opt-in CPU max-frequency cap (`/etc/default/audiophile-cpu-states`, re-tunable without re-running the wizard) and always-on memory/MM jitter reducers (THP, KSM, NUMA balancing); walkthrough recommends BIOS-side CPU Boost off + OS→BIOS consolidation path for the max-freq cap
- [x] **v1.5** — Stable interface naming by MAC (opt-in, default Y): NICs renamed to `eth-lan` / `eth-diretta` via udev `.link` drop-ins, surviving NIC swap, added PCIe card, and GPU insert/remove. Single canonical Diretta `.link` carrying rename + MTU + offload-off (gso/tso/gro/lro). `diretta-net-toggle` hardened with cache validation, actionable error messages when networkd is inactive, and a new `purge` subcommand for recovery from NetworkManager. Menu shows the module-file prefix (`NN`) next to each name
- [x] **v1.6** — `extras/lyrion-fedora.sh` (LMS installer) made arch-aware: auto-resolves the correct download for both x86_64 and aarch64
- [x] **v1.7** — Newbie walkthrough updated to cover slim2UPnP (module 12) prompts in the step-by-step table (EN + FR)
- [x] **v1.8** — DRUP tuner re-pinned to a fixed upstream commit (grubby cmdline regression fix)
- [x] **v1.9** — Wizard menu sample and documentation refreshed for module 12 (slim2UPnP); module described in guides
- [x] **v2.0.0** — **RAM mode** (module 13): run the entire root filesystem from RAM via full overlayfs (custom dracut initramfs module, zero disk I/O during playback) or `systemd.volatile=state` (lightweight `/var`-only variant). Per-core CPU frequency tuning re-tunable at any time via `scripts/cpu-states-tune.sh`. Per-core DRUP poll-mode. Validated on ARM64 by Auke. Functional parity with the Raspberry Pi sibling repo.
- [x] **v2.1.0** — `99-finalize` reporting fixes: DRUP false-negative in the systemctl check, slim2UPnP detection added (with a binary fallback), extended RAM-mode live status.
- [x] **v2.2.0** — **RAM-mode warning at wizard launch**: `setup.sh` now warns *before any action* when the running session discards writes on reboot (overlayfs: everything is lost; `systemd.volatile`: `/var` only), so a full install — or a `git pull` — can no longer evaporate silently at the next boot. Detection reads `/proc/cmdline` (the kernel actually running), not `grubby` (which reports the *next* boot). Reported by Auke.
- [x] **v2.3.0** — **Unattended mode** (`--unattended`, `--answers`): the entire wizard runs without a TTY, every prompt driven by `UA_<KEY>` environment variables. Enables scripted appliance builds, kickstart `%post`, and CI provisioning. `extras/answers-example.env` lists all keys with their defaults. Contributed by Bertrand Clech (renesenses).
- [x] **v2.3.1** — RAM-mode disable bug fix: id-based BLS targeting fixes `Disable` sometimes leaving `audiophile.overlay=1` in the boot cmdline (ambiguous `grubby --update-kernel=DEFAULT` resolution when the recovery entry shares a kernel path). The module now reads `saved_entry` from grubenv, edits the BLS entry directly, and verifies every add/remove. A reboot prompt is offered immediately after disable. Reported and fixed by Auke.
- [x] **v2.3.2** — RAM-mode preflight `/boot` space check: `dracut -f` briefly needs room for the old *and* new initramfs at once (it writes a `.tmp` file next to the existing image before replacing it) — a small `/boot` with several kernels retained can run out mid-rebuild with a cryptic zstd "No space left on device" error. The module now checks free space before calling dracut and fails with an actionable message instead. Reported by hd3291.
- [x] **v2.3.3** — Module 04's optional `/var/tmp` tmpfs (256M) starved dracut's own initramfs build directory on every subsequent kernel update — the same cryptic "No space left on device" as v2.3.2, but from a different cause: plenty of room on `/boot`, none in dracut's scratch space. Now redirects dracut's `tmpdir` to `/tmp` (not resized by this repo) alongside the `/var/tmp` tmpfs entry. Diagnosed live on Dominique's TuneOS box.
- [x] **v2.4.0** — RAM-mode gains a **Persistent paths** option (module 13, new `P` menu choice): bind-mount an app's mutable state from `/home` (untouched by either RAM-mode strategy) onto the path it actually expects, so it survives reboots even though `/var` — or all of `/` under overlay — is otherwise wiped every time. Auto-detects installed apps and offers two verified presets (Lyrion Music Server, Tune Server's self-updating `/opt/tune`), migrates existing data on first enable, and a symmetric removal restores it. Independent of the Enable/Disable choice. Inspired by a HiFi-forum member's manual LMS bind-mount setup; validated end-to-end on real hardware (add, reboot-survival, remove/restore) — one stdin-redirection bug in the removal prompt found and fixed along the way.
- [x] **v2.4.1** — Newbie walkthrough (EN + FR) updated to cover v2.4.0's `P` (Persistent paths) prompt for module 13.
- [x] **v2.4.2** — Two Persistent-paths bugs found while wiring this into Tune OS, reported by Bertrand Clech (renesenses): the Tune Server preset only detected `tune-server.service` — a name inferred from the binary/`WorkingDirectory`, never actually confirmed against a real unit file — and so silently never matched Tune OS's real unit (`tune.service`); no error, no prompt, just skipped. Separately, `RAM_MODE_ACTION=e` never reached the persistent-paths questions in a single unattended pass (the dispatch was a single-choice `case`), so `UA_RAM_PERSIST_TUNE=Y` had no effect unless the wizard was re-run separately with `action=p`. Fixed: the preset now checks a comma-separated list of candidate unit names (`tune.service,tune-server.service`), and enabling RAM mode (`E`) now automatically walks into the Persistent-paths questions right after — one pass covers both.
- [x] **v2.4.3** — A third Persistent-paths bug, again found by Bertrand Clech (renesenses) while checking the feature's premise against Tune OS's actual disk layout: the source-path check was a `/home/*` string prefix, not an actual mount-boundary test. On a host where `/home` is just an ordinary directory inside `/` — Tune OS's kickstart included, single grown root partition, no separate `/home` at all — RAM-mode overlay wraps `/home` along with everything else, so a pair would report success and `findmnt` would show it "active" while the data still vanished on reboot: a false sense of protection, worse than none. `_ram_persist_add_pair` now resolves the actual backing filesystem of both the source and `/` (`findmnt --target`, walking up to the nearest existing ancestor since the source often doesn't exist yet) and **refuses** — not just warns — when they match, on every host layout, not only Tune OS's.
- [x] **v2.4.4** — Each preset's source path can now be overridden per-host without an interactive prompt: `UA_<key>_SOURCE` (e.g. `UA_RAM_PERSIST_TUNE_SOURCE=/persist/tune-data`), a silent env-var lookup, not a new question in the wizard's UI. For hosts with no `/home` at all — Tune OS has no user accounts whatsoever (services run as `root`, console is autologin) so provisioning a `/home` partition there would exist purely to satisfy a path convention. `_ram_persist_add_pair`'s v2.4.3 mount-boundary check is still the actual enforcement; this only changes *where* it's allowed to point. Agreed with Bertrand Clech (renesenses), who'll provision a dedicated persistent mount (`/persist`-style) on Tune OS's side.

### Planned

- [ ] Optional advanced path: compile the vanilla PREEMPT_RT kernel from source
- [x] Optional config-file mode for unattended provisioning
- [ ] Spanish translation

## Optional companion — Lyrion Music Server (LMS)

`extras/lyrion-fedora.sh` is an **optional** installer for [Lyrion Music Server](https://lyrion.org/) (formerly Logitech Media Server), contributed by tester **Auke**. It is **not** part of the wizard's main install — run it on its own:

```bash
sudo ./extras/lyrion-fedora.sh
```

LMS is a music **server** (library, scanning, transcoding, web UI on `:9000`). The audiophile-preferred topology runs it on a **separate box** and keeps this host a minimal player — co-locate it only if you don't have another server. It pairs naturally with the **slim2Diretta** player (module 11) for a self-contained server + player on one machine.

Arch-aware: the LMS RPM is **noarch** (one package for every architecture), so the same auto-resolved download works on x86_64 and aarch64, and the only arch-specific bit (the bundled `sox` helper path, `Bin/<arch>-linux/`) is derived at runtime. Originally written/tested on aarch64; an x86_64 confirming run on real hardware is welcome.

## Versioning

Releases follow [semver](https://semver.org/) (`vMAJOR.MINOR.PATCH`) and are marked with **annotated** git tags (`git tag -a`).

**A published tag is never rewritten or force-moved.** Once `vX.Y.Z` is pushed, it points at that commit forever — safe to pin against in downstream projects, packaging, or CI.

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
