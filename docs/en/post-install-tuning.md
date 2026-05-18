# Post-Install Tuning Reference

This document explains every tuning the wizard applies — what it changes, why it matters for audio playback, where the change is persisted, and how to revert it manually if needed.

The wizard always writes a full log to `/var/log/audiophile-setup/<timestamp>.log` so you can see exactly what happened on your specific machine.

## Module execution order

The modules in `modules/` are numbered (`00-` through `99-`) and executed in that order. You can run a single module with `sudo ./setup.sh --only <name>`.

| # | Module | What it does | Status |
|---|--------|--------------|--------|
| 00 | preflight | Verify Fedora 43/44, x86_64, Secure Boot off, IPv6 on; auto-install curl/mokutil/grubby/dnf-plugins-core | Done |
| 01 | kernel-rt | Install a PREEMPT_RT kernel (choice: vanilla `kernel-rt` *(default)* or `kernel-cachyos-rt`), set it as the default GRUB entry | Done |
| 02 | system-tuning | Run the DRUP `diretta-renderer-tuner` (`apply`) for isolcpus/IRQ/slice/governor | Done |
| 03 | network-stack | Keep NetworkManager (tuned) or switch to systemd-networkd — user's choice | Done |
| 04 | tmpfs-disk | Make journald volatile, optionally move `/var/log` and `/var/tmp` to tmpfs | Done |
| 05 | services-cleanup | Disable bluetooth/cups/avahi/etc.; optionally disable firewalld and SELinux | Done |
| 06 | cpu-states | governor=performance, disable turbo/boost, disable deep c-states (systemd oneshot) | Done |
| 07 | sysctl-network | Bump global socket buffers (`rmem_max` / `wmem_max` / backlog). MTU + ethtool live in 10/11. | Done |
| 08 | tuned-profile | Install tuned, apply the `latency-performance` profile | Done |
| 09 | swap-disable | `swapoff -a` + `vm.swappiness=0` + comment swap out of `/etc/fstab` | Done |
| 10 | install-drup | Install DirettaRendererUPnP via its own `install.sh`, wire up `/etc/default/diretta-renderer` | Done |
| 11 | install-slim2diretta | Install slim2Diretta via its own `install.sh`, wire up `/etc/default/slim2diretta` | Done |
| 99 | finalize | Sanity-check every module's mark, then offer a reboot | Done |

---

## Module details

The authoritative, always-current description of each module is the header comment block at the top of the corresponding `modules/NN-*.sh` file (kept in sync with the code). The interactive prompts and recommended answers are summarised in the [newbie walkthrough §13](newbie-walkthrough.md#13-answer-the-per-module-prompts). The notes below give the "what and why" at a glance.

### 00 — preflight

Hard pre-conditions, all blocking: distribution is Fedora 43 or 44, architecture is x86_64, Secure Boot is OFF (the vanilla kernel-rt can't be signed), IPv6 is enabled (the Diretta protocol requires it). As a safety net it also installs the small CLI tools the wizard itself needs (`curl`, `mokutil`, `grubby`, `dnf-plugins-core`) if they're missing.

### 01 — kernel-rt

Prompts for the RT flavour (both keep PREEMPT_RT), enables the matching COPR, installs the kernel, then makes it the default boot entry so the single planned reboot lands on the realtime kernel:

- **vanilla `kernel-rt`** *(default, safest)* — COPR `@kernel-vanilla/stable` (Thorsten Leemhuis):

  ```bash
  dnf -y copr enable @kernel-vanilla/stable
  dnf -y install kernel-rt kernel-rt-core kernel-rt-modules
  ```

- **`kernel-cachyos-rt`** *(opt-in)* — COPR `bieszczaders/kernel-cachyos` (CachyOS RT + BORE):

  ```bash
  dnf -y copr enable bieszczaders/kernel-cachyos
  dnf -y install kernel-cachyos-rt kernel-cachyos-rt-devel-matched
  ```

Then `grubby --set-default=` the chosen variant's `/boot/vmlinuz-*`. Reference: https://fedoraproject.org/wiki/Kernel_Vanilla_Repositories. The non-RT `kernel-cachyos-lto` is intentionally **not** offered (it drops PREEMPT_RT). Variant-aware idempotency: skips when the chosen variant is already installed and already the default. A previously installed RT kernel is kept (roll back from the GRUB menu).

### 02 — system-tuning

Downloads the `diretta-renderer-tuner.sh` (or its `-nosmt` variant) from DirettaRendererUPnP and runs it with `apply`. The tuner handles:

- Kernel cmdline (`isolcpus`, `nohz_full`, `rcu_nocbs`, `irqaffinity`, optional `nosmt`)
- CPU governor service (`cpu-performance-diretta*.service`)
- Systemd slice with `AllowedCPUs`
- NIC IRQ affinity service
- Thread round-robin distribution on isolated cores

Fetched fresh so the module works even without DRUP installed (slim2Diretta-only setups).

### 03 — network-stack

Interactive choice between three options:

- **K — Keep NetworkManager (tuned)** *(default)*. Installs `NetworkManager-tui` if missing (so `nmtui` is available) and disables `NetworkManager-wait-online.service` to avoid boot delays. Minimises the lockout risk on SSH-only hosts. Fine NIC-side tuning (disabling MDNS / link-local resolution on the Diretta NIC) happens later in `install-drup` / `install-slim2diretta` once the interface is known.
- **S — Switch to systemd-networkd**. Opt-in for users who observe periodic dropouts on NetworkManager (Qobuz on some hardware) or want a fully deterministic stack. Generates a `.network` file per active physical ethernet interface from the current NM state (DHCP or static), enables `systemd-networkd` + `systemd-resolved`, disables and masks `NetworkManager`, and limits `systemd-networkd-wait-online` to the WAN interface (the one with the default route) via a drop-in so a Diretta point-to-point NIC doesn't stall the boot for two minutes.
- **N — Skip**. Leaves the network stack untouched.

Generated files carry a `# Generated by fedora-audiophile-setup` header line. If a later run picks "Keep NetworkManager" while the host is currently on networkd, the module reverts the switch safely: it re-enables / unmasks NM, disables networkd, and removes only files bearing that header — files the user wrote by hand are left alone.

### 04 — tmpfs-disk

Two steps:

1. **Journald volatile** — a drop-in under `/etc/systemd/journald.conf.d/` sets `Storage=volatile`. Logs live in `/run/log/journal/` (already a tmpfs) and are cleared on reboot. journald is restarted so it takes effect immediately.
2. **Optional `/var/log` and `/var/tmp` as tmpfs** via `/etc/fstab` (asked interactively, default yes). `/var/tmp` keeps `mode=1777`. fstab entries are tagged so re-runs are no-ops.

### 05 — services-cleanup

Disables a fixed list of services and timers an audiophile host never needs (bluetooth, cups, avahi, ModemManager, packagekit, udisks2, abrt\*, fwupd\*, `dnf-makecache.timer`, `*-updatedb.timer`). `static` units (e.g. `cups.service`) are stopped rather than disabled. Two interactive prompts, both default **Y** on a dedicated host: disable `firewalld`, and disable SELinux (`setenforce 0` + `SELINUX=disabled` in `/etc/selinux/config`).

### 06 — cpu-states

Installs a systemd oneshot service plus its `/usr/local/sbin` script that, on every boot:

- sets `scaling_governor=performance` on every CPU
- disables turbo/boost (Intel pstate `no_turbo`, fallback `cpufreq/boost` for AMD/acpi-cpufreq)
- disables c-states deeper than C0/C1 (cpuidle `state2+`)

Best-effort writes (missing sysfs nodes skipped). Coexists with the DRUP tuner's governor service — both write the same values.

### 07 — sysctl-network

Strictly host-wide socket-buffer knobs, written to `/etc/sysctl.d/99-audiophile-network.conf` and reloaded via `sysctl --system`:

| Knob | Value | Purpose |
|---|---|---|
| `net.core.rmem_max` / `wmem_max` | 16 MB | Max per-socket buffer a process can request. |
| `net.core.rmem_default` / `wmem_default` | 4 MB | Buffer for sockets that don't request explicitly. |
| `net.core.optmem_max` | 64 KB | Ancillary cmsg room (multicast, hw-timestamping). |
| `net.core.netdev_max_backlog` | 5000 | Packets buffered between NIC IRQ and userland reads. |

**MTU and ethtool link tuning are not done here.** On a Diretta host there are typically two NICs (WAN/LAN at MTU 1500, Diretta point-to-point up to MTU 16128), and only the install modules know which NIC is which — so MTU + ethtool live in `10-install-drup` / `11-install-slim2diretta`.

### 08 — tuned-profile

Installs `tuned` if absent, enables it, and applies the built-in `latency-performance` profile. tuned is a conservative baseline; modules 06 and 07 layer their explicit values on top via systemd units that run after `multi-user.target`, so our values win on any overlap. Idempotent: skips the `tuned-adm profile` call when the target profile is already active.

### 09 — swap-disable

`swapoff -a` (probed via `/proc/swaps` first), `vm.swappiness=0` via `/etc/sysctl.d/99-audiophile-swap.conf`, and active swap lines in `/etc/fstab` commented out with a recognisable tag. fstab is backed up before edit. awk matches the fstab `swap` fstype on field 3, so device paths containing "swap" don't false-positive.

### 10 — install-drup

Optional (asked up front). Detects `SUDO_USER` (DRUP `install.sh` refuses root) and the manually-downloaded Diretta SDK under `~/DirettaHostSDK_*`. Pre-installs build deps, lets the user pick the Diretta-side NIC, pre-creates a NetworkManager profile for it (so DRUP `install.sh` can persist the MTU), clones DRUP, runs `./install.sh` (optionally `LLVM=1` for a Clang+LTO build), then `systemd/install-systemd.sh`, and post-processes `/etc/default/diretta-renderer` (`INTERFACE`, `TARGET_INTERFACE`, `TARGET`). MTU + jumbo are answered once, inside DRUP's own installer. Service is enabled but not started — it waits for the reboot.

### 11 — install-slim2diretta

Same shape as module 10, for slim2Diretta. Standalone (works without DRUP). Lighter — no FFmpeg-from-source. Reuses the Diretta-NIC choice, asks an optional LMS server IP, runs slim2Diretta's interactive `install.sh` (which deploys the binary, service and config itself), then post-processes `/etc/default/slim2diretta` (`TARGET`, `TARGET_INTERFACE`, optional `SLIM2DIRETTA_OPTS`). Service enabled, not started.

### 99 — finalize

Pure inspection — touches nothing. For each module the wizard ran, the finalizer looks for the mark that module would have left (kernel-rt installed and default boot entry, journald drop-in, fstab tmpfs entries, sysctl drop-ins, `audiophile-cpu-states.service`, tuned profile, swap status, jumbo MTU on a NIC, the renderer services). Each line prints either `[OK]` or `[--]`. A `[--]` is not a failure — it just means the matching module was skipped or its target was optional.

After the summary, the user is prompted `Reboot now? [y/N]` (default N — gives you time to inspect first). The whole point of the wizard is to apply everything in one pass and reboot once; the finalizer is where that reboot happens (or where you copy the suggested verification commands and reboot yourself).

---

## Reverting

The wizard does **not** provide a per-module rollback (a deliberate design choice — see [design-notes](design-notes.md)). It is safe to re-run instead: every module is idempotent and converges rather than stacking changes.

To undo a change by hand, the generated artefacts are easy to find — they are tagged or live in well-known paths:

- Files carrying a `# Generated by fedora-audiophile-setup` (or `# audiophile-setup`) header: the systemd-networkd `.network` files, the journald and sysctl drop-ins, the swap fstab lines.
- `audiophile-cpu-states.service` + `/usr/local/sbin/audiophile-cpu-states.sh`.
- `tuned-adm profile balanced` reverts module 08.
- `grubby --set-default` to an earlier kernel reverts the boot side of module 01 (the package can stay installed).
- The DRUP / slim2Diretta services have their own `uninstall-systemd.sh` (DRUP) / reinstall path.

`fstab` is backed up to `fstab.audiophile-bak.<timestamp>` before the swap edit, so the original is always recoverable.
