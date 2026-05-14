#!/bin/bash
#
# 10-install-drup — orchestrate the DirettaRendererUPnP install.
#
# Flow (asks Y/N upfront — module is optional):
#   1. Detect SUDO_USER (DRUP install.sh refuses root)
#   2. Detect Diretta SDK under /home/$SUDO_USER/DirettaHostSDK_*
#      (SDK download is manual — licence "personal use only" — diretta.link)
#   3. Install ethtool (used by start-renderer at runtime)
#   4. Interactive NIC selection (Diretta side + control-point side). We
#      need to know these to post-process /etc/default/diretta-renderer
#      afterwards. MTU + .link/nmcli persistence is intentionally NOT done
#      here: DRUP's own install.sh prompts for MTU and persists it via
#      nmcli, so duplicating it would re-ask the user the same question.
#   5. git clone DRUP into $HOME/DirettaRendererUPnP (as $SUDO_USER)
#   6. Run ./install.sh as $SUDO_USER in a real TTY (~30 min for FFmpeg
#      build); skipped if the binary already exists. THIS is where the user
#      answers the MTU question, and where DRUP's install.sh writes the
#      nmcli MTU on the Diretta NIC.
#   7. Run systemd/install-systemd.sh as root (copies binary, conf, service)
#   8. Post-process /etc/default/diretta-renderer: set INTERFACE,
#      TARGET_INTERFACE, TARGET
#   9. systemctl enable (don't start — service waits for next reboot)
#

set -euo pipefail

readonly _DRUP_REPO_URL="https://github.com/cometdom/DirettaRendererUPnP.git"
readonly _DRUP_CONF_FILE="/etc/default/diretta-renderer"
readonly _DRUP_SERVICE="diretta-renderer.service"

log_step "Install DirettaRendererUPnP"

if ! ask_yes_no "Install DirettaRendererUPnP?" Y; then
    log_info "Skipping DRUP install."
    return 0 2>/dev/null || exit 0
fi

# --- 1. Detect the unprivileged user that ran sudo ----------------------

if [[ -z "${SUDO_USER:-}" || "${SUDO_USER}" == "root" ]]; then
    log_error "DRUP's install.sh refuses to run as root."
    log_error "Please launch this wizard via 'sudo' from a regular user account (not a direct root login)."
    exit 1
fi
_drup_user="$SUDO_USER"
_drup_home=$(getent passwd "$_drup_user" | cut -d: -f6)
if [[ -z "$_drup_home" || ! -d "$_drup_home" ]]; then
    log_error "Cannot resolve home directory of user '${_drup_user}'."
    exit 1
fi
log_info "DRUP will be built as user '${_drup_user}' (home: ${_drup_home})."

# --- 2. Find the manually-downloaded Diretta SDK ------------------------

_drup_sdk=$(find "$_drup_home" -maxdepth 1 -type d -name 'DirettaHostSDK_*' 2>/dev/null \
    | sort -V | tail -1)
if [[ -z "$_drup_sdk" ]]; then
    log_error "Diretta SDK not found under ${_drup_home}/DirettaHostSDK_*"
    log_error ""
    log_error "The SDK is licensed 'for personal use only' and must be downloaded manually:"
    log_error "  1. Visit https://www.diretta.link/hostsdk.html"
    log_error "  2. Download the latest DirettaHostSDK_*.tar.zst"
    log_error "  3. Copy it to ${_drup_home}/ on this host"
    log_error "  4. Extract:  tar --zstd -xf DirettaHostSDK_*.tar.zst"
    log_error "  5. Re-run:   sudo ./setup.sh --only install-drup"
    exit 1
fi
log_info "Found Diretta SDK: ${_drup_sdk}"

# --- 3. Pre-install build prerequisites ---------------------------------
#
# Defensive: DRUP install.sh runs its own 'install_base_dependencies' step
# but some pre-flight checks (e.g. invoking a tool before the dnf install
# block) can fail when the tool is missing. Installing the same list ahead
# of time makes install.sh's step a no-op and avoids that class of fail.
# ethtool stays in the list because start-renderer uses it at runtime.

log_info "Installing DRUP build prerequisites"
run_cmd dnf -y install \
    git gcc-c++ make pkg-config wget nasm yasm \
    libupnp-devel ethtool

# --- 4. NIC selection ----------------------------------------------------

# Physical ethernet interfaces — any link state. A Diretta target NIC
# typically has carrier=down at install time (target not yet powered or
# cabled), so filtering on operstate=up would hide it.
_drup_eth_ifaces() {
    local sys iface typ
    for sys in /sys/class/net/*; do
        iface=$(basename "$sys")
        [[ "$iface" == "lo" ]] && continue
        [[ "$(readlink -f "$sys")" == *"/devices/virtual/"* ]] && continue
        typ=$(cat "${sys}/type" 2>/dev/null || echo "")
        [[ "$typ" == "1" ]] || continue
        echo "$iface"
    done
}

# Annotate an interface with its link state and IPv4 (if any) for the menu.
_drup_describe_iface() {
    local iface="$1" state addr
    state=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "?")
    addr=$(ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{print $4; exit}')
    if [[ -n "$addr" ]]; then
        printf '%s  (link %s, %s)' "$iface" "$state" "$addr"
    else
        printf '%s  (link %s, no IPv4)' "$iface" "$state"
    fi
}

# IMPORTANT: the menu must print to stderr — the caller captures stdout via
# $(_drup_pick_iface ...) to get the chosen iface, so anything written to
# stdout BEFORE the final echo would be silently swallowed (user would see
# only "Number [1]:" without the menu above it).
_drup_pick_iface() {
    local prompt="$1"; shift
    local choices=("$@")
    {
        echo
        echo "${prompt}"
        local i
        for i in "${!choices[@]}"; do
            printf "  %d) %s\n" "$((i+1))" "$(_drup_describe_iface "${choices[i]}")"
        done
    } >&2
    while true; do
        read -r -p "Number [1]: " _pick
        _pick="${_pick:-1}"
        if [[ "$_pick" =~ ^[1-9][0-9]*$ ]] && (( _pick >= 1 && _pick <= ${#choices[@]} )); then
            echo "${choices[$((_pick-1))]}"
            return 0
        fi
        echo "Invalid choice." >&2
    done
}

mapfile -t _drup_ifaces < <(_drup_eth_ifaces)
if [[ ${#_drup_ifaces[@]} -eq 0 ]]; then
    log_error "No physical ethernet interface found — cannot configure DRUP."
    exit 1
elif [[ ${#_drup_ifaces[@]} -eq 1 ]]; then
    _drup_diretta_iface="${_drup_ifaces[0]}"
    _drup_control_iface="${_drup_ifaces[0]}"
    log_info "Single NIC '${_drup_diretta_iface}' will serve both UPnP (control points) and Diretta target."
else
    _drup_diretta_iface=$(_drup_pick_iface "Which NIC is connected to the Diretta target (audio side)?" "${_drup_ifaces[@]}")
    if [[ ${#_drup_ifaces[@]} -eq 2 ]]; then
        for _iface in "${_drup_ifaces[@]}"; do
            [[ "$_iface" != "$_drup_diretta_iface" ]] && _drup_control_iface="$_iface"
        done
    else
        # 3+ NICs: ask explicitly
        _drup_remaining=()
        for _iface in "${_drup_ifaces[@]}"; do
            [[ "$_iface" != "$_drup_diretta_iface" ]] && _drup_remaining+=("$_iface")
        done
        _drup_control_iface=$(_drup_pick_iface "Which NIC is the control-point side (UPnP: Audirvana/Roon)?" "${_drup_remaining[@]}")
    fi
    log_info "Diretta NIC:       ${_drup_diretta_iface}"
    log_info "Control-point NIC: ${_drup_control_iface}"
fi

# Ensure NetworkManager has a connection profile for the Diretta NIC. If it
# doesn't, DRUP install.sh later fails to persist the MTU ("Could not find
# NetworkManager connection for <iface>") because the NIC is unmanaged. The
# NIC is typically link-down at this stage (Diretta target not powered yet),
# so NM never auto-created a profile. Create a minimal one: link-local on
# both IPv4 and IPv6 (Diretta speaks L2/raw sockets — no IP needed on the
# Diretta link), autoconnect on so it survives reboots.
_drup_ensure_nm_connection() {
    local iface="$1"
    is_service_active NetworkManager || return 0
    if ! command -v nmcli >/dev/null 2>&1; then
        log_warn "NM is active but nmcli is missing — cannot pre-create profile for ${iface}."
        return 0
    fi

    # Count profiles named "diretta-<iface>" by UUID. Earlier wizard
    # versions could create duplicates (DEVICE column was '--' for inactive
    # connections, missing the existence check). We now recover from any
    # leftover duplicates: delete them all and recreate a clean one.
    # Single-quotes preserve the iface in awk.
    local -a our_uuids=()
    local uuid
    while IFS= read -r uuid; do
        [[ -n "$uuid" ]] && our_uuids+=("$uuid")
    done < <(nmcli -t -f UUID,NAME connection show 2>/dev/null \
        | awk -F: -v n="diretta-${iface}" '$2==n {print $1}')

    if [[ ${#our_uuids[@]} -gt 1 ]]; then
        log_warn "Found ${#our_uuids[@]} duplicate NM profiles named 'diretta-${iface}' — deleting all and recreating one clean."
        for uuid in "${our_uuids[@]}"; do
            run_cmd nmcli connection delete "$uuid"
        done
        # Fall through to the create step below.
    elif [[ ${#our_uuids[@]} -eq 1 ]]; then
        log_info "NM profile 'diretta-${iface}' already present (UUID ${our_uuids[0]}) — skipping."
        return 0
    fi

    # No diretta-* profile, but some OTHER profile may still be bound to
    # this iface (e.g. an auto-created one). Don't stomp on it.
    local bound
    bound=$(nmcli -t -f GENERAL.CONNECTION device show "$iface" 2>/dev/null | cut -d: -f2)
    if [[ -n "$bound" && "$bound" != "--" ]]; then
        log_info "NM profile already bound to ${iface}: '${bound}' — skipping."
        return 0
    fi

    log_info "Creating minimal NM profile for ${iface} (link-local v4+v6, autoconnect)."
    run_cmd nmcli connection add type ethernet \
        ifname "$iface" \
        con-name "diretta-${iface}" \
        ipv4.method link-local \
        ipv6.method link-local \
        connection.autoconnect yes
}
_drup_ensure_nm_connection "$_drup_diretta_iface"

# --- 5. git clone DRUP as the unprivileged user --------------------------
#
# Note: MTU prompt + persistence intentionally skipped here. DRUP's own
# install.sh has a "=== Network Configuration ===" section that asks the
# Diretta NIC, jumbo Y/N, and MTU (9014 / 16128) and writes the value via
# nmcli. We let it own that interaction so the user answers only once.

_drup_dir="${_drup_home}/DirettaRendererUPnP"
if [[ -d "${_drup_dir}/.git" ]]; then
    log_info "DRUP repo already cloned at ${_drup_dir}"
else
    log_info "Cloning DRUP repo to ${_drup_dir} (as ${_drup_user})"
    run_cmd sudo -u "$_drup_user" git clone "$_DRUP_REPO_URL" "$_drup_dir"
fi

# --- 6. Run DRUP install.sh as the user (TTY-direct, ~30 min) ------------

_drup_binary="${_drup_dir}/bin/DirettaRendererUPnP"
_drup_run_install=1
if [[ -f "$_drup_binary" ]]; then
    log_info "DRUP binary already exists at ${_drup_binary}."
    if ! ask_yes_no "Re-run ./install.sh (e.g. to rebuild with Clang+LTO or a different option)?" N; then
        log_info "Keeping the existing binary — skipping ./install.sh."
        _drup_run_install=0
    fi
fi

if [[ "$_drup_run_install" -eq 1 ]]; then
    # Clang + LTO build is reported to improve audio quality on both DRUP
    # and slim2Diretta. install.sh auto-installs clang and lld when LLVM=1
    # is set in the environment.
    _drup_llvm_prefix=""
    if ask_yes_no "Build DRUP with Clang + LTO (recommended for sound quality)?" Y; then
        _drup_llvm_prefix="LLVM=1 "
        log_info "Will pass LLVM=1 to ./install.sh (clang + lld auto-installed by install.sh)."
    fi

    log_warn "About to run DRUP ./install.sh as user '${_drup_user}'."
    log_warn "It compiles FFmpeg from source — expect ~30 minutes. Answer its prompts."
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_info "DRY-RUN: would execute as ${_drup_user}: cd ${_drup_dir} && ${_drup_llvm_prefix}./install.sh"
    else
        # Direct exec (no run_cmd / tee pipe) so install.sh keeps its TTY.
        # -i = login shell so PATH/HOME are clean for the user.
        sudo -u "$_drup_user" -i bash -c "cd '${_drup_dir}' && ${_drup_llvm_prefix}./install.sh"
    fi
fi

# --- 7. Install the systemd service via DRUP's own installer -------------

log_info "Running ${_drup_dir}/systemd/install-systemd.sh (root) to deploy /opt/diretta-renderer-upnp + service unit."
if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    log_info "DRY-RUN: would execute: bash ${_drup_dir}/systemd/install-systemd.sh"
else
    bash "${_drup_dir}/systemd/install-systemd.sh"
fi

# --- 8. Post-process /etc/default/diretta-renderer -----------------------

# install-systemd.sh only copies the template when the conf doesn't exist;
# either way we (re)apply our three known variables idempotently.
_drup_set_conf_var() {
    local var="$1" val="$2"
    if [[ ! -f "$_DRUP_CONF_FILE" ]]; then
        return 0
    fi
    if grep -qE "^${var}=" "$_DRUP_CONF_FILE"; then
        sed -i -E "s|^${var}=.*$|${var}=\"${val}\"|" "$_DRUP_CONF_FILE"
    else
        echo "${var}=\"${val}\"" >> "$_DRUP_CONF_FILE"
    fi
}

log_info "Setting INTERFACE / TARGET_INTERFACE / TARGET in ${_DRUP_CONF_FILE}"
if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    log_info "DRY-RUN: would set INTERFACE=${_drup_control_iface}, TARGET_INTERFACE=$([[ "$_drup_control_iface" == "$_drup_diretta_iface" ]] && echo '<empty: single NIC>' || echo "${_drup_diretta_iface}"), TARGET=1"
else
    _drup_set_conf_var INTERFACE "$_drup_control_iface"
    if [[ "$_drup_control_iface" == "$_drup_diretta_iface" ]]; then
        # Single-NIC: leave TARGET_INTERFACE empty so DRUP auto-detects.
        _drup_set_conf_var TARGET_INTERFACE ""
    else
        _drup_set_conf_var TARGET_INTERFACE "$_drup_diretta_iface"
    fi
    _drup_set_conf_var TARGET 1
fi

# --- 9. Enable the service (don't start — wait for reboot) --------------

run_cmd systemctl enable "$_DRUP_SERVICE"

log_info "DRUP installed. The service is enabled and will start at next reboot."
log_info "Review ${_DRUP_CONF_FILE} before reboot if you need to tune CPU affinity, IRQ pinning, buffers, etc."
