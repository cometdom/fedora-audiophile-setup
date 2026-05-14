#!/bin/bash
#
# 11-install-slim2diretta — orchestrate the slim2Diretta install.
#
# Standalone (not coupled to 10-install-drup): a user may want only
# slim2Diretta.
#
# Flow:
#   1. Detect SUDO_USER (slim2Diretta install.sh refuses root)
#   2. Find Diretta SDK under /home/$SUDO_USER/DirettaHostSDK_*
#   3. Install ethtool (used by start-slim2diretta at runtime)
#   4. Interactive NIC selection (Diretta side). Needed to post-process
#      /etc/default/slim2diretta afterwards. MTU + .link/nmcli is NOT done
#      here: slim2Diretta's install.sh menu has "5) Configure network"
#      that prompts for MTU and persists via nmcli — we let it own that.
#   5. Ask optional LMS server IP (empty → auto-discover via Slimproto)
#   6. git clone slim2Diretta into $HOME/slim2Diretta (as $SUDO_USER)
#   7. Run ./install.sh as $SUDO_USER in a real TTY (interactive menu).
#      install.sh deploys /usr/local/bin/slim2diretta + service + conf
#      itself. The user picks option 1 (Full install) and then option 5
#      ("Configure network") for the MTU step.
#   8. Post-process /etc/default/slim2diretta: set TARGET, TARGET_INTERFACE,
#      optionally SLIM2DIRETTA_OPTS with the LMS IP.
#   9. systemctl enable (no start — service waits for next reboot).
#

set -euo pipefail

readonly _S2D_REPO_URL="https://github.com/cometdom/slim2Diretta.git"
readonly _S2D_CONF_FILE="/etc/default/slim2diretta"
readonly _S2D_SERVICE="slim2diretta.service"

log_step "Install slim2Diretta"

if ! ask_yes_no "Install slim2Diretta?" Y; then
    log_info "Skipping slim2Diretta install."
    return 0 2>/dev/null || exit 0
fi

# --- 1. Detect unprivileged user -----------------------------------------

if [[ -z "${SUDO_USER:-}" || "${SUDO_USER}" == "root" ]]; then
    log_error "slim2Diretta's install.sh refuses to run as root."
    log_error "Please launch this wizard via 'sudo' from a regular user account."
    exit 1
fi
_s2d_user="$SUDO_USER"
_s2d_home=$(getent passwd "$_s2d_user" | cut -d: -f6)
if [[ -z "$_s2d_home" || ! -d "$_s2d_home" ]]; then
    log_error "Cannot resolve home directory of user '${_s2d_user}'."
    exit 1
fi
log_info "slim2Diretta will be built as user '${_s2d_user}' (home: ${_s2d_home})."

# --- 2. Find the Diretta SDK ---------------------------------------------

_s2d_sdk=$(find "$_s2d_home" -maxdepth 1 -type d -name 'DirettaHostSDK_*' 2>/dev/null \
    | sort -V | tail -1)
if [[ -z "$_s2d_sdk" ]]; then
    log_error "Diretta SDK not found under ${_s2d_home}/DirettaHostSDK_*"
    log_error "Download manually from https://www.diretta.link/hostsdk.html (licence: personal use only),"
    log_error "extract it to ${_s2d_home}/, then re-run: sudo ./setup.sh --only install-slim2diretta"
    exit 1
fi
log_info "Found Diretta SDK: ${_s2d_sdk}"

# --- 3. Runtime prerequisite ---------------------------------------------

if ! has_package ethtool; then
    log_info "Installing ethtool (used by start-slim2diretta for link tuning)"
    run_cmd dnf -y install ethtool
fi

# --- 4. NIC selection ----------------------------------------------------
#
# Note: MTU prompt + persistence intentionally skipped here. slim2Diretta's
# own install.sh menu includes "5) Configure network" which prompts for the
# Diretta NIC + MTU and persists via nmcli. We let it own that interaction
# so the user answers MTU only once.

# List physical ethernet interfaces — any link state. Diretta target NIC
# often has carrier=down at install time (target not yet powered or cabled).
_s2d_eth_ifaces() {
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
_s2d_describe_iface() {
    local iface="$1" state addr
    state=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null || echo "?")
    addr=$(ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{print $4; exit}')
    if [[ -n "$addr" ]]; then
        printf '%s  (link %s, %s)' "$iface" "$state" "$addr"
    else
        printf '%s  (link %s, no IPv4)' "$iface" "$state"
    fi
}

mapfile -t _s2d_ifaces < <(_s2d_eth_ifaces)
if [[ ${#_s2d_ifaces[@]} -eq 0 ]]; then
    log_error "No physical ethernet interface found — cannot configure slim2Diretta."
    exit 1
elif [[ ${#_s2d_ifaces[@]} -eq 1 ]]; then
    _s2d_diretta_iface="${_s2d_ifaces[0]}"
    log_info "Single NIC '${_s2d_diretta_iface}' will be used as the Diretta NIC."
else
    echo
    echo "Which NIC is connected to the Diretta target (audio side)?"
    for i in "${!_s2d_ifaces[@]}"; do
        printf "  %d) %s\n" "$((i+1))" "$(_s2d_describe_iface "${_s2d_ifaces[i]}")"
    done
    while true; do
        read -r -p "Number [1]: " _s2d_pick
        _s2d_pick="${_s2d_pick:-1}"
        if [[ "$_s2d_pick" =~ ^[1-9][0-9]*$ ]] && (( _s2d_pick >= 1 && _s2d_pick <= ${#_s2d_ifaces[@]} )); then
            _s2d_diretta_iface="${_s2d_ifaces[$((_s2d_pick-1))]}"
            break
        fi
        echo "Invalid choice."
    done
fi

# --- 5. Optional LMS server IP -------------------------------------------

echo
read -r -p "LMS server IP (leave empty for Slimproto auto-discovery): " _s2d_lms_ip
if [[ -n "${_s2d_lms_ip}" ]]; then
    _s2d_opts="-s ${_s2d_lms_ip}"
    log_info "slim2Diretta will connect to LMS at ${_s2d_lms_ip}."
else
    _s2d_opts=""
    log_info "slim2Diretta will auto-discover the LMS server."
fi

# --- 6. Clone slim2Diretta as the user -----------------------------------

_s2d_dir="${_s2d_home}/slim2Diretta"
if [[ -d "${_s2d_dir}/.git" ]]; then
    log_info "slim2Diretta repo already cloned at ${_s2d_dir}"
else
    log_info "Cloning slim2Diretta repo to ${_s2d_dir} (as ${_s2d_user})"
    run_cmd sudo -u "$_s2d_user" git clone "$_S2D_REPO_URL" "$_s2d_dir"
fi

# --- 7. Run install.sh as the user (TTY-direct) --------------------------

_s2d_binary="/usr/local/bin/slim2diretta"
if [[ -x "$_s2d_binary" ]]; then
    log_info "slim2Diretta binary already installed at ${_s2d_binary} — skipping ./install.sh."
else
    log_warn "About to run slim2Diretta ./install.sh as user '${_s2d_user}'."
    log_warn "Answer its interactive prompts (codec selection menu, etc.)."
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_info "DRY-RUN: would execute as ${_s2d_user}: cd ${_s2d_dir} && ./install.sh"
    else
        sudo -u "$_s2d_user" -i bash -c "cd '${_s2d_dir}' && ./install.sh"
    fi
fi

# --- 8. Post-process /etc/default/slim2diretta ---------------------------

_s2d_set_conf_var() {
    local var="$1" val="$2"
    if [[ ! -f "$_S2D_CONF_FILE" ]]; then
        return 0
    fi
    if grep -qE "^${var}=" "$_S2D_CONF_FILE"; then
        sed -i -E "s|^${var}=.*$|${var}=\"${val}\"|" "$_S2D_CONF_FILE"
    else
        echo "${var}=\"${val}\"" >> "$_S2D_CONF_FILE"
    fi
}

log_info "Setting TARGET / TARGET_INTERFACE${_s2d_opts:+ / SLIM2DIRETTA_OPTS} in ${_S2D_CONF_FILE}"
if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    log_info "DRY-RUN: would set TARGET=1, TARGET_INTERFACE=${_s2d_diretta_iface}${_s2d_opts:+, SLIM2DIRETTA_OPTS=${_s2d_opts}}"
else
    _s2d_set_conf_var TARGET 1
    _s2d_set_conf_var TARGET_INTERFACE "$_s2d_diretta_iface"
    if [[ -n "$_s2d_opts" ]]; then
        _s2d_set_conf_var SLIM2DIRETTA_OPTS "$_s2d_opts"
    fi
fi

# --- 9. Enable service (don't start — wait for reboot) -------------------

run_cmd systemctl enable "$_S2D_SERVICE"

log_info "slim2Diretta installed. The service is enabled and will start at next reboot."
log_info "Review ${_S2D_CONF_FILE} before reboot to tune player name, codec options, CPU affinity, etc."
