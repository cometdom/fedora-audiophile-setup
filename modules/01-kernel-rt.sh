#!/bin/bash
#
# 01-kernel-rt — install a PREEMPT_RT kernel (vanilla or CachyOS-RT) and set
# it as the default GRUB boot entry.
#
# Two RT choices (both keep PREEMPT_RT — the project pillar):
#   1) vanilla kernel-rt  — COPR @kernel-vanilla/stable (Thorsten Leemhuis,
#      official Fedora kernel-vanilla). Default, safest, newbie-friendly.
#      Reference: https://fedoraproject.org/wiki/Kernel_Vanilla_Repositories
#   2) kernel-cachyos-rt  — COPR bieszczaders/kernel-cachyos (CachyOS RT +
#      BORE + Cachy tweaks, GCC build). Opt-in, aligned with the DRUP Fedora
#      guide / community.
#
# Switching strategy: the chosen variant is installed and set as the default
# GRUB entry; the other variant (if present) is NOT removed, so a bad boot
# is one GRUB menu pick away from recovery.
#
# Idempotent and variant-aware: if the chosen variant's packages are already
# installed AND the default boot entry already points at that variant's
# vmlinuz, the module does nothing.
#
# Pre-conditions enforced by 00-preflight: Fedora 43/44, x86_64, Secure Boot OFF.
#

set -euo pipefail

log_step "Install a PREEMPT_RT kernel"

# Variant state (filled by _kernel_pick_variant).
_kr_variant=""          # vanilla | cachyos-rt
_kr_copr=""             # COPR repo to enable
_kr_label=""            # human label for logs
_kr_pkgs=()             # packages to dnf install
_kr_core_pkg=""         # the -core package that owns the vmlinuz (drives detection)

_kernel_check_internet() {
    if command -v curl >/dev/null 2>&1; then
        if curl -fsS -m 5 -o /dev/null https://fedoraproject.org 2>/dev/null; then
            return 0
        fi
    elif command -v ping >/dev/null 2>&1; then
        if ping -c 1 -W 3 fedoraproject.org >/dev/null 2>&1; then
            return 0
        fi
    fi
    log_error "Cannot reach the network — installing a kernel requires internet access (COPR). Check your connection and retry."
    exit 1
}

# Print the /boot vmlinuz of the chosen variant (most recent), or empty.
#
# Derived from RPM, not from the file name: a kernel's vmlinuz is
# /boot/vmlinuz-<VERSION>-<RELEASE>.<ARCH>, and the variant's -core package
# carries exactly that V-R-arch. Name-grepping is unreliable — the vanilla
# kernel-rt encodes "rt" in its RELEASE (e.g. ...-rt1.fc44...) but the
# CachyOS-RT vmlinuz is just vmlinuz-7.0.5-cachyos1.fc44.x86_64 with NO
# "rt" anywhere in the name. Querying the -core package is deterministic
# for both. If several versions are installed, take the newest (sort -V).
_kernel_find_vmlinuz() {
    [[ -n "$_kr_core_pkg" ]] || return 0
    local kver v
    kver=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' "$_kr_core_pkg" 2>/dev/null \
        | sort -V | tail -1 || true)
    [[ -n "$kver" ]] || return 0
    v="/boot/vmlinuz-${kver}"
    [[ -f "$v" ]] && echo "$v"
}

_kernel_default_is_chosen() {
    local def want
    def=$(grubby --default-kernel 2>/dev/null || true)
    want=$(_kernel_find_vmlinuz)
    [[ -n "$want" && "$def" == "$want" ]]
}

_kernel_already_done() {
    local p
    for p in "${_kr_pkgs[@]}"; do
        has_package "$p" || return 1
    done
    _kernel_default_is_chosen
}

_kernel_pick_variant() {
    echo
    echo "Which realtime kernel?"
    echo "  1) vanilla kernel-rt   — official Fedora kernel-vanilla COPR (safest, default)"
    echo "  2) kernel-cachyos-rt   — CachyOS RT (BORE + Cachy tweaks), bieszczaders COPR"
    echo
    local choice
    read -r -p "Choose [1]: " choice
    case "${choice:-1}" in
        1|"")
            _kr_variant="vanilla"
            _kr_copr="@kernel-vanilla/stable"
            _kr_label="vanilla kernel-rt"
            _kr_pkgs=(kernel-rt kernel-rt-core kernel-rt-modules)
            _kr_core_pkg="kernel-rt-core"
            ;;
        2)
            _kr_variant="cachyos-rt"
            _kr_copr="bieszczaders/kernel-cachyos"
            _kr_label="kernel-cachyos-rt"
            # Package set follows the DRUP Fedora guide; -devel-matched pulls
            # the matching core/modules. Adjust here (and _kr_core_pkg) if
            # upstream changes the subpackage names.
            _kr_pkgs=(kernel-cachyos-rt kernel-cachyos-rt-devel-matched)
            _kr_core_pkg="kernel-cachyos-rt-core"
            ;;
        *)
            log_error "Invalid choice: ${choice}"
            exit 1
            ;;
    esac
    log_info "Selected: ${_kr_label} (COPR ${_kr_copr})"
}

_kernel_enable_copr() {
    if ! has_package dnf-plugins-core; then
        log_info "Installing dnf-plugins-core (required for 'dnf copr')."
        run_cmd dnf -y install dnf-plugins-core
    fi
    log_info "Enabling COPR ${_kr_copr}"
    run_cmd dnf -y copr enable "$_kr_copr"
}

_kernel_install_packages() {
    log_info "Installing ${_kr_pkgs[*]}"
    run_cmd dnf -y install "${_kr_pkgs[@]}"
}

_kernel_set_default() {
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_info "DRY-RUN: would locate the ${_kr_label} vmlinuz and set it as GRUB default via grubby."
        return 0
    fi
    local vmlinuz
    vmlinuz=$(_kernel_find_vmlinuz)
    if [[ -z "$vmlinuz" ]]; then
        log_error "${_kr_label} is installed but no matching /boot/vmlinuz-* was found. Cannot set the default GRUB entry."
        exit 1
    fi
    log_info "Setting default GRUB entry: ${vmlinuz}"
    run_cmd grubby --set-default="$vmlinuz"
}

# --- Dispatch -------------------------------------------------------------

if ! ask_yes_no "Install/refresh a PREEMPT_RT kernel (recommended)?" Y; then
    log_warn "User declined the RT kernel. The audiophile setup will be incomplete; subsequent modules may misbehave."
    return 0 2>/dev/null || exit 0
fi

_kernel_pick_variant

if _kernel_already_done; then
    log_info "${_kr_label} already installed and set as the default boot entry — skipping."
    return 0 2>/dev/null || exit 0
fi

_kernel_check_internet
_kernel_enable_copr
_kernel_install_packages
_kernel_set_default

log_info "${_kr_label} installed and set as default. It will boot at next reboot."
log_info "Any previously installed RT kernel is kept — pick it from the GRUB menu if you need to roll back."
