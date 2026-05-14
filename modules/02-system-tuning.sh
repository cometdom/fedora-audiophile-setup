#!/bin/bash
#
# 02-system-tuning — apply system-level tuning via the DRUP tuner script.
#
# Delegates to diretta-renderer-tuner.sh (or its -nosmt variant) from
# DirettaRendererUPnP, which configures:
#   - kernel cmdline (isolcpus, nohz_full, rcu_nocbs, irqaffinity, opt. nosmt)
#   - cpu-performance-diretta*.service
#   - systemd slice with AllowedCPUs
#   - NIC IRQ affinity service
#   - thread round-robin on isolated cores
#
# The script is fetched fresh from raw.githubusercontent.com so this module
# is usable even when DRUP itself is not installed (e.g. slim2Diretta-only).
#
# Idempotency: if cpu-performance-diretta*.service is already installed, we
# treat the tuning as applied and skip by default (user can force re-run).
#

set -euo pipefail

readonly _TUNER_BASE_URL="https://raw.githubusercontent.com/cometdom/DirettaRendererUPnP/main"
readonly _TUNER_REGULAR="diretta-renderer-tuner.sh"
readonly _TUNER_NOSMT="diretta-renderer-tuner-nosmt.sh"
readonly _TUNER_CACHE_DIR="/var/cache/audiophile-setup"

log_step "Apply system-level tuning (DRUP tuner)"

_tuning_already_applied() {
    find /etc/systemd/system -maxdepth 1 -name 'cpu-performance-diretta*.service' -type f 2>/dev/null \
        | grep -q .
}

_tuning_check_internet() {
    if command -v curl >/dev/null 2>&1 \
        && curl -fsS -m 5 -o /dev/null https://raw.githubusercontent.com 2>/dev/null; then
        return 0
    fi
    log_error "Cannot reach raw.githubusercontent.com — the DRUP tuner script must be downloaded. Check your network and retry."
    exit 1
}

# Echoes the local path to the downloaded tuner on stdout. All log output is
# sent to stderr so it doesn't pollute the captured path.
_tuning_download() {
    local script_name="$1"
    local dest="${_TUNER_CACHE_DIR}/${script_name}"

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        echo "${dest}"
        return 0
    fi

    if ! mkdir -p "${_TUNER_CACHE_DIR}"; then
        log_error "Cannot create cache directory ${_TUNER_CACHE_DIR}" >&2
        exit 1
    fi
    if ! curl -fsSL -o "${dest}" "${_TUNER_BASE_URL}/${script_name}"; then
        log_error "Failed to download ${script_name} from ${_TUNER_BASE_URL}" >&2
        exit 1
    fi
    chmod +x "${dest}"
    echo "${dest}"
}

if _tuning_already_applied; then
    log_info "DRUP tuner already applied to this host (cpu-performance-diretta*.service present)."
    if ! ask_yes_no "Re-run the DRUP tuner anyway?" N; then
        return 0 2>/dev/null || exit 0
    fi
fi

_tuning_check_internet

if ask_yes_no "Use the -nosmt tuner variant (disables Hyper-Threading / SMT — recommended on Intel HT or AMD SMT CPUs for lowest jitter)?" N; then
    _tuner_script="${_TUNER_NOSMT}"
else
    _tuner_script="${_TUNER_REGULAR}"
fi

if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    log_info "DRY-RUN: would download ${_TUNER_BASE_URL}/${_tuner_script} to ${_TUNER_CACHE_DIR}/"
else
    log_info "Downloading ${_tuner_script} from upstream DRUP"
fi

_tuner_path=$(_tuning_download "${_tuner_script}")

log_info "Running ${_tuner_script}"
if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    log_info "DRY-RUN: would execute: ${_tuner_path}"
else
    # Direct exec (not via run_cmd) so the tuner keeps a real TTY for its
    # own interactive prompts. The setup.sh log retains the "Running ..."
    # marker; tuner output is shown live to the user.
    "${_tuner_path}"
fi

log_info "System tuning applied. The kernel cmdline change takes effect on next reboot."
