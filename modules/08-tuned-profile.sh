#!/bin/bash
#
# 08-tuned-profile — install tuned and apply latency-performance.
#
# tuned provides a conservative baseline (governor, c-state max, swappiness,
# basic sysctl). Our explicit modules (06-cpu-states, 07-sysctl-network)
# layer on top via systemd services that run after multi-user.target, so any
# conflicting value from our modules wins. Keeping the tuned layer means a
# clean revert is just 'tuned-adm profile balanced' away.
#
# Idempotent: dnf install is a no-op if tuned is present, and we skip the
# 'tuned-adm profile' call when the target profile is already active.
#

set -euo pipefail

readonly _TUNED_PROFILE="latency-performance"

log_step "Apply tuned profile (${_TUNED_PROFILE})"

if ! has_package tuned; then
    log_info "Installing tuned"
    run_cmd dnf -y install tuned
else
    log_info "tuned already installed."
fi

run_cmd systemctl enable --now tuned

if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    log_info "DRY-RUN: would set tuned profile to '${_TUNED_PROFILE}'."
else
    _tuned_current=$(tuned-adm active 2>/dev/null | sed -n 's/^Current active profile: //p')
    if [[ "$_tuned_current" == "$_TUNED_PROFILE" ]]; then
        log_info "tuned profile already '${_TUNED_PROFILE}' — skipping."
    else
        log_info "Setting tuned profile: ${_TUNED_PROFILE} (was: ${_tuned_current:-<none>})"
        run_cmd tuned-adm profile "$_TUNED_PROFILE"
    fi
fi

log_info "tuned profile ${_TUNED_PROFILE} active."
