#!/bin/bash
#
# 00-preflight — verify hard pre-conditions and install the small set of CLI
# tools the wizard depends on at runtime.
#
# Order:
#   1. Distribution is Fedora 43 or 44     (blocking)
#   2. Architecture is x86_64              (blocking)
#   3. Install missing wizard prerequisites (curl, mokutil, grubby,
#      dnf-plugins-core) — safety net so the user can forget the documented
#      'dnf install' step and still get a clean run.
#   4. Secure Boot is OFF                  (blocking — uses mokutil from #3)
#   5. IPv6 is enabled                     (blocking)
#
# Checks 1-2 and 4-5 are blocking and not gated by DRY_RUN — a dry-run that
# skipped them would hide blockers the real run will hit anyway. The
# safety-net install at #3 goes through run_cmd, so DRY_RUN previews it
# without actually installing.
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
        log_error "Unsupported distribution: ${ID:-unknown}. This wizard targets Fedora 43 or 44 only."
        exit 1
    fi
    case "${VERSION_ID:-}" in
        43|44) ;;
        *)
            log_error "Unsupported Fedora release: ${VERSION_ID:-unknown}. This wizard targets Fedora 43 or 44 only."
            exit 1
            ;;
    esac
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

_preflight_install_tools() {
    local missing=()
    command -v curl    >/dev/null 2>&1 || missing+=(curl)
    command -v mokutil >/dev/null 2>&1 || missing+=(mokutil)
    command -v grubby  >/dev/null 2>&1 || missing+=(grubby)
    has_package dnf-plugins-core       || missing+=(dnf-plugins-core)

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_info "Required CLI tools already present (curl, mokutil, grubby, dnf-plugins-core)."
        return 0
    fi
    log_info "Installing missing wizard prerequisites: ${missing[*]}"
    run_cmd dnf -y install "${missing[@]}"
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
_preflight_install_tools
_preflight_check_secure_boot
_preflight_check_ipv6

log_info "Preflight: all checks passed."
