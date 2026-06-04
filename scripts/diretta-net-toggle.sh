#!/bin/bash
#
# diretta-net-toggle.sh — switch a Diretta host's two NICs between:
#
#   independent  LAN NIC = LAN (DHCP), Diretta NIC = Diretta link
#                (link-local only, L2). The normal audiophile mode.
#
#   bridge       LAN NIC + Diretta NIC enslaved into a bridge that takes
#                the LAN DHCP lease. The Diretta target (cabled to the
#                Diretta NIC) then sits on the LAN segment and is
#                reachable from any LAN host — handy to check/apply a
#                target firmware update WITHOUT unplugging/recabling it.
#
# systemd-networkd ONLY (NetworkManager variant may come later). The
# bridge mode is TRANSIENT: pinned to MTU 1500 for LAN compatibility.
# Switch back to 'independent' for listening (the jumbo udev .link on the
# Diretta NIC then applies again).
#
# Interface resolution (no hard-coded names), in priority order:
#   1. env vars  DIRETTA_LAN_IFACE / DIRETTA_TARGET_IFACE  (expert override)
#   2. saved mapping  /etc/diretta-net-toggle.conf
#   3. auto-detect    LAN = default-route iface; Diretta = the other
#                     physical ethernet (works on a 2-NIC host)
#   4. interactive    pick from a list (state link + IPv4 shown)
# The resolved pair is persisted to the state file so that switching back
# from 'bridge' (where the default route is on the bridge, not a physical
# NIC) still maps correctly. Delete the state file to force re-detection.
#
# Usage:
#   sudo ./scripts/diretta-net-toggle.sh status
#   sudo ./scripts/diretta-net-toggle.sh bridge
#   sudo ./scripts/diretta-net-toggle.sh independent
#
# WARNING: switching to/from 'bridge' moves the LAN IP between the LAN NIC
# and the bridge, so an SSH session over the LAN WILL drop briefly —
# prefer a local console, or reconnect after.
#

set -euo pipefail

BRIDGE="diretta-br0"
NETDIR="/etc/systemd/network"
STATE_FILE="/etc/diretta-net-toggle.conf"
TAG="# Managed by diretta-net-toggle"

LAN_IFACE=""
DIRETTA_IFACE=""

_info()  { echo "[net-toggle] $*"; }
_warn()  { echo "[net-toggle] WARNING: $*" >&2; }
_err()   { echo "[net-toggle] ERROR: $*" >&2; }

_require_root() {
    if [[ $EUID -ne 0 ]]; then
        _err "must run as root (use sudo)."
        exit 1
    fi
}

_require_networkd() {
    if ! systemctl is-active --quiet systemd-networkd; then
        _err "systemd-networkd is not active — this tool only supports systemd-networkd."
        if systemctl is-active --quiet NetworkManager; then
            _err "You are currently on NetworkManager. Two options:"
            _err "  1. Switch the network stack: 'sudo ./setup.sh --only network-stack' (choose S),"
            _err "     reboot, then re-run this tool."
            _err "  2. If you only want to undo a previous run of this tool (clean up its files"
            _err "     and let NM re-attach to the freed interfaces), run: 'sudo $0 purge'"
            _err "     — that works regardless of which network stack is active."
        else
            _err "Activate systemd-networkd first, or use 'sudo $0 purge' to clean up files left"
            _err "by a previous run of this tool."
        fi
        exit 1
    fi
    # Both stacks active is a fragile state: NM and networkd fight for control
    # of the same interfaces, and any bridge/independent switch tends to be
    # undone by NM after a few seconds. Surface this loudly — silent failure
    # is what tripped the user on 2026-06-02.
    if systemctl is-active --quiet NetworkManager; then
        _warn "BOTH NetworkManager AND systemd-networkd are active. This is a fragile state:"
        _warn "the two managers will fight for control of the same interfaces, and a 'bridge'"
        _warn "or 'independent' switch is likely to be partially undone by NM after a few"
        _warn "seconds (you may see the connection drop unexpectedly). Strongly recommended:"
        _warn "  sudo systemctl disable --now NetworkManager"
        _warn "or switch cleanly via 'sudo ./setup.sh --only network-stack' (choose S)."
        _confirm "Continue anyway?" || { _info "aborted."; exit 0; }
    fi
}

# --- Interface discovery --------------------------------------------------

# Physical ethernet interfaces (excludes lo, virtual devices incl. the
# bridge, non-ethernet). One per line.
_phys_eth_ifaces() {
    local sys iface
    for sys in /sys/class/net/*; do
        iface=$(basename "$sys")
        [[ "$iface" == "lo" ]] && continue
        [[ "$(readlink -f "$sys")" == */devices/virtual/* ]] && continue
        [[ "$(cat "${sys}/type" 2>/dev/null)" == "1" ]] || continue
        echo "$iface"
    done
}

_default_route_iface() {
    ip -o route show default 2>/dev/null | awk '{print $5; exit}'
}

_iface_descr() {
    local iface="$1" state addr
    state=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "?")
    addr=$(ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{print $4; exit}')
    printf '%s  (link %s, %s)' "$iface" "$state" "${addr:-no IPv4}"
}

_save_state() {
    cat > "$STATE_FILE" <<EOF
# diretta-net-toggle interface mapping
# Auto-generated. Delete this file to force re-detection.
LAN_IFACE=${LAN_IFACE}
DIRETTA_IFACE=${DIRETTA_IFACE}
EOF
    _info "saved interface mapping to ${STATE_FILE} (LAN=${LAN_IFACE}, Diretta=${DIRETTA_IFACE})."
}

# Parse the state file WITHOUT sourcing it (no arbitrary code execution).
# Validates that the cached interfaces still exist in /sys/class/net before
# accepting them — otherwise re-detection is forced. Necessary because the
# kernel-assigned NIC names (enpXsY) can shift across PCI re-enumerations
# (NIC swap, GPU insert/remove, added PCIe card) or be renamed entirely by
# a .link rule (eth-lan / eth-diretta). Trusting a stale cache after that
# produces phantom file writes (10-enp5s0.network etc.) and a bridge with
# no slaves, which is what tripped the user on 2026-06-01.
_load_state() {
    [[ -r "$STATE_FILE" ]] || return 1
    local l d
    l=$(grep -E '^LAN_IFACE=' "$STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)
    d=$(grep -E '^DIRETTA_IFACE=' "$STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)
    [[ -n "$l" && -n "$d" ]] || return 1
    if [[ ! -e "/sys/class/net/${l}" || ! -e "/sys/class/net/${d}" ]]; then
        _warn "cached interfaces (LAN=${l}, Diretta=${d}) no longer exist — discarding ${STATE_FILE} and re-detecting. This is normal after a NIC swap, added PCIe card, GPU change, or stable-naming rename."
        return 1
    fi
    LAN_IFACE="$l"; DIRETTA_IFACE="$d"
    return 0
}

# Try to auto-detect: LAN = default-route iface (must be a physical eth),
# Diretta = the only other physical eth. Returns 1 if ambiguous.
_auto_detect() {
    local -a eth=()
    local i
    while IFS= read -r i; do eth+=("$i"); done < <(_phys_eth_ifaces)
    [[ ${#eth[@]} -eq 2 ]] || return 1
    local def; def=$(_default_route_iface)
    [[ -n "$def" ]] || return 1
    local is_phys=0 other=""
    for i in "${eth[@]}"; do
        [[ "$i" == "$def" ]] && is_phys=1 || other="$i"
    done
    [[ $is_phys -eq 1 && -n "$other" ]] || return 1
    LAN_IFACE="$def"; DIRETTA_IFACE="$other"
    return 0
}

_pick_iface() {
    local prompt="$1"; shift
    local -a choices=("$@") i pick
    {
        echo
        echo "$prompt"
        for i in "${!choices[@]}"; do
            printf '  %d) %s\n' "$((i+1))" "$(_iface_descr "${choices[i]}")"
        done
    } >&2
    while true; do
        read -r -p "Number [1]: " pick
        pick="${pick:-1}"
        if [[ "$pick" =~ ^[1-9][0-9]*$ ]] && (( pick >= 1 && pick <= ${#choices[@]} )); then
            echo "${choices[$((pick-1))]}"
            return 0
        fi
        echo "Invalid choice." >&2
    done
}

_interactive_resolve() {
    local -a eth=()
    local i
    while IFS= read -r i; do eth+=("$i"); done < <(_phys_eth_ifaces)
    if [[ ${#eth[@]} -lt 2 ]]; then
        _err "need at least two physical ethernet NICs; found ${#eth[@]}. Plug both NICs in, or set DIRETTA_LAN_IFACE / DIRETTA_TARGET_IFACE."
        exit 1
    fi
    LAN_IFACE=$(_pick_iface "Which NIC is connected to your LAN/router?" "${eth[@]}")
    local -a rest=()
    for i in "${eth[@]}"; do
        [[ "$i" != "$LAN_IFACE" ]] && rest+=("$i")
    done
    if [[ ${#rest[@]} -eq 1 ]]; then
        DIRETTA_IFACE="${rest[0]}"
    else
        DIRETTA_IFACE=$(_pick_iface "Which NIC is connected to the Diretta target?" "${rest[@]}")
    fi
}

# Resolve LAN_IFACE/DIRETTA_IFACE. Mode "ro" = read-only, never prompts or
# writes (for 'status'); returns 1 if it cannot resolve. Mode "rw" =
# may prompt and persists the mapping (for 'bridge'/'independent').
_resolve_ifaces() {
    local mode="$1"

    if [[ -n "${DIRETTA_LAN_IFACE:-}" && -n "${DIRETTA_TARGET_IFACE:-}" ]]; then
        LAN_IFACE="$DIRETTA_LAN_IFACE"; DIRETTA_IFACE="$DIRETTA_TARGET_IFACE"
        [[ "$mode" == "rw" ]] && _save_state
        return 0
    fi
    if _load_state; then
        return 0
    fi
    if _auto_detect; then
        [[ "$mode" == "rw" ]] && _save_state
        return 0
    fi
    if [[ "$mode" == "ro" ]]; then
        return 1
    fi
    _warn "could not auto-detect the NIC roles — asking."
    _interactive_resolve
    _save_state
    return 0
}

# --- Managed files --------------------------------------------------------

_is_managed() {
    [[ -f "$1" ]] && [[ "$(head -1 "$1" 2>/dev/null)" == "$TAG" ]]
}

_managed_candidates() {
    printf '%s\n' \
        "${NETDIR}/10-${LAN_IFACE}.network" \
        "${NETDIR}/10-${DIRETTA_IFACE}.network" \
        "${NETDIR}/15-${BRIDGE}.netdev" \
        "${NETDIR}/20-${BRIDGE}.network"
}

_clean_managed() {
    local f
    while IFS= read -r f; do
        if _is_managed "$f"; then
            _info "removing ${f}"
            rm -f "$f"
        fi
    done < <(_managed_candidates)
}

_current_mode() {
    if _is_managed "${NETDIR}/15-${BRIDGE}.netdev"; then
        echo "bridge"
    elif _is_managed "${NETDIR}/10-${LAN_IFACE}.network"; then
        echo "independent"
    else
        echo "unknown"
    fi
}

_warn_unmanaged_conflicts() {
    local f
    for f in "${NETDIR}/10-${LAN_IFACE}.network" "${NETDIR}/10-${DIRETTA_IFACE}.network"; do
        if [[ -f "$f" ]] && ! _is_managed "$f"; then
            _warn "${f} exists and is NOT managed by this tool (likely the wizard's). It will be overwritten; 'independent' restores a working Diretta config."
        fi
    done
}

_write_independent() {
    cat > "${NETDIR}/10-${LAN_IFACE}.network" <<EOF
${TAG}
[Match]
Name=${LAN_IFACE}

[Network]
DHCP=yes
EOF
    cat > "${NETDIR}/10-${DIRETTA_IFACE}.network" <<EOF
${TAG}
[Match]
Name=${DIRETTA_IFACE}

[Network]
# Diretta speaks L2 on this link — no routable IP needed. The target may
# be powered off at boot, so configure the iface even without carrier.
LinkLocalAddressing=yes
ConfigureWithoutCarrier=yes
EOF
}

_write_bridge() {
    # Pin the bridge's MAC to the LAN NIC's. A Linux bridge otherwise
    # adopts the lowest MAC among its ports; if that's the Diretta NIC,
    # the DHCP request goes out with a different MAC, the router hands out
    # a DIFFERENT IP, and you have to reconnect to a new address (and
    # again when un-bridging). Keeping the LAN NIC's identity → same DHCP
    # lease → same IP across independent ⇄ bridge.
    local lan_mac
    lan_mac=$(cat "/sys/class/net/${LAN_IFACE}/address" 2>/dev/null || true)
    {
        echo "${TAG}"
        echo "[NetDev]"
        echo "Name=${BRIDGE}"
        echo "Kind=bridge"
        if [[ -n "$lan_mac" ]]; then
            echo "MACAddress=${lan_mac}"
        fi
    } > "${NETDIR}/15-${BRIDGE}.netdev"
    if [[ -n "$lan_mac" ]]; then
        _info "bridge MAC pinned to ${LAN_IFACE} (${lan_mac}) — same DHCP lease/IP kept."
    else
        _warn "could not read ${LAN_IFACE} MAC; bridge MAC not pinned — the LAN IP may change while bridged."
    fi
    cat > "${NETDIR}/10-${LAN_IFACE}.network" <<EOF
${TAG}
[Match]
Name=${LAN_IFACE}

[Network]
Bridge=${BRIDGE}

[Link]
MTUBytes=1500
EOF
    cat > "${NETDIR}/10-${DIRETTA_IFACE}.network" <<EOF
${TAG}
[Match]
Name=${DIRETTA_IFACE}

[Network]
Bridge=${BRIDGE}

[Link]
MTUBytes=1500
EOF
    cat > "${NETDIR}/20-${BRIDGE}.network" <<EOF
${TAG}
[Match]
Name=${BRIDGE}

[Network]
DHCP=yes

[Link]
MTUBytes=1500
EOF
}

_apply() {
    _info "reloading systemd-networkd…"
    networkctl reload 2>/dev/null || true
    systemctl restart systemd-networkd
    _info "done. Give it a few seconds; if you were on SSH over the LAN, reconnect."
}

_confirm() {
    local ans
    read -r -p "$1 [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

cmd_status() {
    if _resolve_ifaces ro; then
        echo "LAN NIC: ${LAN_IFACE}    Diretta NIC: ${DIRETTA_IFACE}"
        echo "Mode (per managed files): $(_current_mode)"
        echo
        echo "Managed files present:"
        local f any=0
        while IFS= read -r f; do
            if _is_managed "$f"; then echo "  $f"; any=1; fi
        done < <(_managed_candidates)
        [[ $any -eq 0 ]] && echo "  (none — network not managed by this tool yet)"
        echo
        echo "Interfaces:"
        ip -br addr show "$LAN_IFACE" 2>/dev/null || true
        ip -br addr show "$DIRETTA_IFACE" 2>/dev/null || true
        ip -br addr show "$BRIDGE" 2>/dev/null || true
    else
        echo "Interface roles not resolved yet (no env override, no ${STATE_FILE},"
        echo "and auto-detection was ambiguous)."
        echo "Run 'sudo $0 independent' (or 'bridge') once to detect/choose and"
        echo "persist the mapping, or set DIRETTA_LAN_IFACE / DIRETTA_TARGET_IFACE."
        echo
        echo "Physical ethernet NICs seen:"
        local i
        while IFS= read -r i; do echo "  $(_iface_descr "$i")"; done < <(_phys_eth_ifaces)
    fi
}

cmd_purge() {
    _require_root
    _info "purging files managed by this tool — works regardless of which network stack is active."

    local f removed=0
    while IFS= read -r f; do
        if _is_managed "$f"; then
            _info "removing $f"
            rm -f "$f"
            removed=$((removed+1))
        fi
    done < <(find "$NETDIR" -maxdepth 1 \( -name '*.network' -o -name '*.netdev' \) -type f 2>/dev/null)

    if [[ -f "$STATE_FILE" ]]; then
        _info "removing $STATE_FILE"
        rm -f "$STATE_FILE"
    fi

    # The .netdev removal alone does NOT delete the bridge device from a
    # running kernel — it just deletes the on-disk definition. The bridge
    # stays as long as networkd hasn't been told to garbage-collect it. The
    # cleanest way out is to delete it explicitly via ip link.
    if [[ -e "/sys/class/net/${BRIDGE}" ]]; then
        _info "removing bridge ${BRIDGE} from kernel"
        ip link del "$BRIDGE" 2>/dev/null || true
    fi

    # Nudge whichever manager is active to re-scan the freed interfaces.
    if systemctl is-active --quiet systemd-networkd; then
        _info "reloading systemd-networkd"
        networkctl reload 2>/dev/null || true
    fi
    if systemctl is-active --quiet NetworkManager; then
        _info "restarting NetworkManager (so it re-attaches to the freed interfaces)"
        systemctl restart NetworkManager || true
    fi

    _info "done. ${removed} managed file(s) removed."
}

cmd_switch() {
    local target="$1"
    _require_root
    _require_networkd
    _resolve_ifaces rw
    _info "LAN NIC: ${LAN_IFACE}   Diretta NIC: ${DIRETTA_IFACE}"
    local cur; cur=$(_current_mode)
    if [[ "$cur" == "$target" ]]; then
        _info "already in '${target}' mode (per managed files)."
        _confirm "Re-apply '${target}' anyway?" || { _info "nothing to do."; return 0; }
    fi
    _warn_unmanaged_conflicts
    _warn "this will restart systemd-networkd. An SSH session over ${LAN_IFACE} may drop."
    _confirm "Switch to '${target}' now?" || { _info "aborted."; return 0; }
    _clean_managed
    case "$target" in
        independent) _write_independent ;;
        bridge)      _write_bridge ;;
    esac
    _apply
    echo
    cmd_status
}

main() {
    case "${1:-}" in
        status)             cmd_status ;;
        bridge|independent) cmd_switch "$1" ;;
        purge)              cmd_purge ;;
        *)
            cat >&2 <<EOF
Usage: sudo $0 {status|bridge|independent|purge}

  status        show resolved NIC roles, current mode, iface state (read-only)
  bridge        enslave LAN+Diretta NICs into ${BRIDGE} (LAN DHCP, MTU
                1500) — target reachable from the LAN, TRANSIENT
  independent   LAN NIC = LAN DHCP, Diretta NIC = link-local — normal mode
  purge         remove every file this tool ever wrote, delete the bridge
                device from the kernel, drop the cached NIC mapping, and
                nudge the active network manager to re-attach. Useful for
                recovery after a partial run, or before switching the
                stack via the wizard. Does NOT require systemd-networkd
                active — runs from NetworkManager too.

NIC roles are auto-detected and saved to ${STATE_FILE}
(delete it to re-detect). Expert override:
  DIRETTA_LAN_IFACE=... DIRETTA_TARGET_IFACE=...
EOF
            exit 2
            ;;
    esac
}

main "$@"
