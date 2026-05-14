#!/bin/bash
#
# 01-kernel-rt — install the PREEMPT_RT kernel from the Fedora kernel-vanilla
# COPR and set it as the default GRUB boot entry.
#
# Reference: https://fedoraproject.org/wiki/Kernel_Vanilla_Repositories
#
# Idempotent: if kernel-rt is already installed and the default boot entry
# already points at an -rt build, the module does nothing.
#
# Pre-conditions enforced by 00-preflight: Fedora 43, x86_64, Secure Boot OFF.
#

set -euo pipefail

log_step "Install PREEMPT_RT kernel (@kernel-vanilla/stable)"

_kernel_rt_check_internet() {
    if command -v curl >/dev/null 2>&1; then
        if curl -fsS -m 5 -o /dev/null https://fedoraproject.org 2>/dev/null; then
            return 0
        fi
    elif command -v ping >/dev/null 2>&1; then
        if ping -c 1 -W 3 fedoraproject.org >/dev/null 2>&1; then
            return 0
        fi
    fi
    log_error "Cannot reach fedoraproject.org — kernel-rt install requires internet access. Check your network and retry."
    exit 1
}

_kernel_rt_default_is_rt() {
    local def
    def=$(grubby --default-kernel 2>/dev/null || true)
    [[ "$def" == *rt* ]]
}

_kernel_rt_already_done() {
    has_package kernel-rt \
        && has_package kernel-rt-core \
        && _kernel_rt_default_is_rt
}

_kernel_rt_enable_copr() {
    if ! has_package dnf-plugins-core; then
        log_info "Installing dnf-plugins-core (required for 'dnf copr')."
        run_cmd dnf -y install dnf-plugins-core
    fi
    log_info "Enabling COPR @kernel-vanilla/stable"
    run_cmd dnf -y copr enable @kernel-vanilla/stable
}

_kernel_rt_install_packages() {
    log_info "Installing kernel-rt + kernel-rt-core + kernel-rt-modules"
    run_cmd dnf -y install kernel-rt kernel-rt-core kernel-rt-modules
}

_kernel_rt_set_default() {
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_info "DRY-RUN: would locate /boot/vmlinuz-*rt* and set it as GRUB default via grubby."
        return 0
    fi
    local rt_vmlinuz
    rt_vmlinuz=$(find /boot -maxdepth 1 -name 'vmlinuz-*rt*' -type f 2>/dev/null | sort -V | tail -1)
    if [[ -z "$rt_vmlinuz" ]]; then
        log_error "kernel-rt is installed but no /boot/vmlinuz-*rt* file was found. Cannot set the default GRUB entry."
        exit 1
    fi
    log_info "Setting default GRUB entry: $rt_vmlinuz"
    run_cmd grubby --set-default="$rt_vmlinuz"
}

if _kernel_rt_already_done; then
    log_info "kernel-rt already installed and set as default boot entry — skipping."
    return 0 2>/dev/null || exit 0
fi

_kernel_rt_check_internet

if ! ask_yes_no "Install PREEMPT_RT kernel from @kernel-vanilla/stable COPR (recommended)?" Y; then
    log_warn "User declined kernel-rt install. The audiophile setup will be incomplete; subsequent modules may misbehave."
    return 0 2>/dev/null || exit 0
fi

_kernel_rt_enable_copr
_kernel_rt_install_packages
_kernel_rt_set_default

log_info "kernel-rt installed. The new kernel will boot at next reboot."
