#!/bin/bash
#
# 00-preflight — verify hard pre-conditions before any tuning module runs.
#
# Checks (all blocking — abort setup.sh on first failure):
#   - Distribution is Fedora 43
#   - Architecture is x86_64
#   - Secure Boot is OFF in firmware (kernel-rt vanilla cannot be signed)
#   - IPv6 is enabled (REQUIRED by the Diretta protocol)
#
# Pure read-only: not gated by DRY_RUN — a dry-run that skipped preflight
# would hide blockers the real run will hit anyway.
#

set -euo pipefail

log_step "Preflight checks"

_preflight_check_os() {
    if [[ ! -r /etc/os-release ]]; then
        log_error "Cannot read /etc/os-release — unsupported system."
        exit 1
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "fedora" ]]; then
        log_error "Unsupported distribution: ${ID:-unknown}. This wizard targets Fedora 43 only."
        exit 1
    fi
    if [[ "${VERSION_ID:-}" != "43" ]]; then
        log_error "Unsupported Fedora release: ${VERSION_ID:-unknown}. This wizard targets Fedora 43 only."
        exit 1
    fi
    log_info "OS: Fedora ${VERSION_ID} (${VARIANT_ID:-unspecified variant})"
}

_preflight_check_arch() {
    local arch
    arch=$(uname -m)
    if [[ "$arch" != "x86_64" ]]; then
        log_error "Unsupported architecture: ${arch}. This wizard targets x86_64 only."
        exit 1
    fi
    log_info "Architecture: ${arch}"
}

_preflight_check_secure_boot() {
    if [[ ! -d /sys/firmware/efi ]]; then
        log_info "Secure Boot: not applicable (legacy BIOS / no EFI firmware)."
        return 0
    fi
    if ! command -v mokutil >/dev/null 2>&1; then
        log_warn "mokutil not installed; cannot verify Secure Boot state. Assuming OFF — verify in BIOS if the kernel-rt step later fails to boot."
        return 0
    fi
    local sb
    sb=$(mokutil --sb-state 2>/dev/null || true)
    case "$sb" in
        *"SecureBoot enabled"*)
            log_error "Secure Boot is ENABLED. The vanilla kernel-rt cannot be signed — disable Secure Boot in BIOS, then re-run."
            exit 1
            ;;
        *"SecureBoot disabled"*)
            log_info "Secure Boot: disabled (OK)"
            ;;
        "")
            log_warn "mokutil returned no output; Secure Boot state could not be determined. Verify in BIOS."
            ;;
        *)
            log_warn "Unexpected mokutil output: ${sb}. Verify Secure Boot is OFF in BIOS."
            ;;
    esac
}

_preflight_check_ipv6() {
    if [[ ! -d /proc/sys/net/ipv6 ]]; then
        log_error "IPv6 is disabled at the kernel level (likely 'ipv6.disable=1' on the kernel cmdline). IPv6 is REQUIRED by the Diretta protocol."
        exit 1
    fi
    local disabled
    disabled=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")
    if [[ "$disabled" != "0" ]]; then
        log_error "IPv6 is disabled (net.ipv6.conf.all.disable_ipv6=${disabled}). IPv6 is REQUIRED by the Diretta protocol — re-enable it before continuing."
        exit 1
    fi
    log_info "IPv6: enabled (OK)"
}

_preflight_check_os
_preflight_check_arch
_preflight_check_secure_boot
_preflight_check_ipv6

log_info "Preflight: all checks passed."
