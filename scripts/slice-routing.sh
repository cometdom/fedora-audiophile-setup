#!/bin/bash
#
# slice-routing.sh — EXPERIMENTAL: corral non-audio processes off the audio
# cores via systemd-slice AllowedCPUs= drop-ins.
#
# What it does
# ============
# Writes two systemd drop-ins:
#   /etc/systemd/system/system.slice.d/audiophile.conf
#   /etc/systemd/system/user.slice.d/audiophile.conf
#
# Each contains `[Slice] AllowedCPUs=<non-audio-cores>`, which constrains
# the entire process tree under system.slice (system services — sshd, NM,
# journald, …) and user.slice (interactive SSH/login sessions) to run only
# on the listed CPUs. Anything not in those slices (kernel work, and any
# DRUP/slim2Diretta thread pinned via SCHED_FIFO + pthread affinity to an
# audio core) bypasses the restriction.
#
# Effect: similar in spirit to isolcpus= but at the cgroup level —
# runtime-modifiable via `systemctl set-property`, no GRUB rebuild, no
# reboot needed.
#
# Relationship with the rest of the wizard
# ========================================
# This is COMPLEMENTARY to the kernel-cmdline isolation already applied by
# the wizard via DRUP's tuner script (isolcpus / nohz_full / rcu_nocbs).
# Slices DO NOT replace nohz_full / rcu_nocbs for last-microsecond
# determinism on the audio path, but they are a more flexible second layer
# for keeping system + user processes confined to a subset of cores without
# rebooting.
#
# Status
# ======
# EXPERIMENTAL personal-sandbox. Not exposed in the main wizard menu. No
# DRUP/S2D service-unit integration in this MVP — those already pin their
# threads to the audio cores via SCHED_FIFO and pthread affinity, so the
# slice constraint on system + user is what materially changes things here.
# If A/B listening tests show this helps perceived sound quality, the
# integration can be promoted to a full module in a follow-up.
#
# Usage
# =====
#   sudo ./scripts/slice-routing.sh apply  [audio-cores]   # e.g. "2,3" or "2-5"
#   sudo ./scripts/slice-routing.sh revert                 # remove the drop-ins
#   sudo ./scripts/slice-routing.sh status                 # show current state
#

set -euo pipefail

readonly TAG="# Managed by audiophile slice-routing"
readonly DROPIN_DIR_SYSTEM="/etc/systemd/system/system.slice.d"
readonly DROPIN_DIR_USER="/etc/systemd/system/user.slice.d"
readonly DROPIN_FILE_SYSTEM="${DROPIN_DIR_SYSTEM}/audiophile.conf"
readonly DROPIN_FILE_USER="${DROPIN_DIR_USER}/audiophile.conf"

_info() { echo "[slice-routing] $*"; }
_warn() { echo "[slice-routing] WARNING: $*" >&2; }
_err()  { echo "[slice-routing] ERROR: $*" >&2; }

_require_root() {
    [[ $EUID -eq 0 ]] || { _err "must run as root (use sudo)."; exit 1; }
}

_total_cores() {
    nproc --all
}

# Parse "2,3" or "2-5" or "2,4-6" → space-separated list of integers.
# Returns 1 on any malformed token.
_expand_cpu_list() {
    local spec="$1" out=""
    local part lo hi i
    local -a parts
    IFS=',' read -ra parts <<< "$spec"
    for part in "${parts[@]}"; do
        part="${part// /}"
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            lo=${BASH_REMATCH[1]}; hi=${BASH_REMATCH[2]}
            (( hi >= lo )) || return 1
            for ((i=lo; i<=hi; i++)); do out+="$i "; done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            out+="$part "
        else
            return 1
        fi
    done
    echo "${out% }"
}

# Print the complement of <audio> in [0..total-1] as a comma-separated list,
# collapsed into ranges where possible (e.g. "0,1,4,5,6,7" → "0-1,4-7").
_invert_and_collapse() {
    local audio_spaced="$1" total="$2"
    local -A audio_set=()
    local c
    for c in $audio_spaced; do audio_set[$c]=1; done

    local out="" run_start="" prev=""
    for ((c=0; c<total; c++)); do
        if [[ -z "${audio_set[$c]:-}" ]]; then
            if [[ -z "$run_start" ]]; then
                run_start=$c; prev=$c
            elif (( c == prev + 1 )); then
                prev=$c
            else
                # flush previous run
                if [[ "$run_start" == "$prev" ]]; then out+="${run_start},"
                else out+="${run_start}-${prev},"
                fi
                run_start=$c; prev=$c
            fi
        fi
    done
    if [[ -n "$run_start" ]]; then
        if [[ "$run_start" == "$prev" ]]; then out+="${run_start}"
        else out+="${run_start}-${prev}"
        fi
    fi
    echo "${out%,}"
}

cmd_apply() {
    _require_root
    local audio_spec="${1:-}"
    if [[ -z "$audio_spec" ]]; then
        echo
        echo "Which cores should be RESERVED for audio (system.slice + user.slice"
        echo "will be confined to the REMAINING cores)? Examples: 2,3 or 2-5"
        read -r -p "Audio cores: " audio_spec
    fi

    local audio_cores
    if ! audio_cores=$(_expand_cpu_list "$audio_spec"); then
        _err "invalid CPU spec '$audio_spec' — expected '2,3' or '2-5' or '2,4-6'."
        exit 1
    fi

    local total
    total=$(_total_cores)
    local c
    for c in $audio_cores; do
        if (( c < 0 || c >= total )); then
            _err "core $c out of range — this host has $total cores (0..$((total-1)))."
            exit 1
        fi
    done

    local non_audio
    non_audio=$(_invert_and_collapse "$audio_cores" "$total")
    if [[ -z "$non_audio" ]]; then
        _err "all $total cores were marked as audio — nothing left for system/user. Aborting."
        exit 1
    fi

    _info "Total cores         : $total (0..$((total-1)))"
    _info "Audio cores         : $(echo $audio_cores | tr ' ' ',')  (free for DRUP/S2D RT threads)"
    _info "system + user slice : $non_audio"

    if [[ -f "$DROPIN_FILE_SYSTEM" ]] || [[ -f "$DROPIN_FILE_USER" ]]; then
        local cur
        cur=$(grep -oP '^AllowedCPUs=\K.*' "$DROPIN_FILE_SYSTEM" 2>/dev/null || echo "?")
        _warn "Existing slice-routing config: AllowedCPUs=$cur. Will be overwritten."
        local ans
        read -r -p "Continue? [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]] || { _info "aborted."; exit 0; }
    fi

    mkdir -p "$DROPIN_DIR_SYSTEM" "$DROPIN_DIR_USER"
    cat > "$DROPIN_FILE_SYSTEM" <<EOF
${TAG}
# system.slice confined to non-audio cores. All system services (sshd, NM,
# journald, etc.) will be scheduled exclusively on these CPUs. RT threads
# in DRUP / slim2Diretta are pinned via SCHED_FIFO + pthread affinity to
# the audio cores and are NOT in this slice — they bypass this restriction.
[Slice]
AllowedCPUs=${non_audio}
EOF
    cat > "$DROPIN_FILE_USER" <<EOF
${TAG}
# user.slice confined to non-audio cores. Interactive sessions (SSH login,
# user services) scheduled on these CPUs only, off the audio cores.
[Slice]
AllowedCPUs=${non_audio}
EOF

    systemctl daemon-reload
    _info "Drop-ins written. system + user slices now constrained at runtime (no reboot needed)."
    _info "Verify: systemctl show system.slice -p AllowedCPUs"
    _info "Revert: sudo $0 revert"
}

cmd_revert() {
    _require_root
    local f removed=0
    for f in "$DROPIN_FILE_SYSTEM" "$DROPIN_FILE_USER"; do
        if [[ -f "$f" ]]; then
            if head -1 "$f" 2>/dev/null | grep -qF "$TAG"; then
                _info "removing $f"
                rm -f "$f"
                removed=$((removed+1))
            else
                _warn "$f exists but is NOT managed by this tool — leaving it alone."
            fi
        fi
    done
    rmdir --ignore-fail-on-non-empty "$DROPIN_DIR_SYSTEM" 2>/dev/null || true
    rmdir --ignore-fail-on-non-empty "$DROPIN_DIR_USER" 2>/dev/null || true
    systemctl daemon-reload
    _info "Done. ${removed} drop-in(s) removed."
}

cmd_status() {
    local total
    total=$(_total_cores)
    echo "Host cores: 0..$((total-1)) (${total} total)"
    echo
    echo "Live AllowedCPUs:"
    echo "  system.slice : $(systemctl show system.slice -p AllowedCPUs --value 2>/dev/null || echo '?')"
    echo "  user.slice   : $(systemctl show user.slice   -p AllowedCPUs --value 2>/dev/null || echo '?')"
    echo
    local f any=0
    for f in "$DROPIN_FILE_SYSTEM" "$DROPIN_FILE_USER"; do
        if [[ -f "$f" ]]; then
            if head -1 "$f" 2>/dev/null | grep -qF "$TAG"; then
                echo "Managed drop-in: $f"
                any=1
            else
                echo "Present but UNMANAGED (not from this tool): $f"
            fi
        fi
    done
    [[ $any -eq 0 ]] && echo "No managed drop-ins. Slices are at defaults (all cores allowed)."
}

main() {
    case "${1:-}" in
        apply)  cmd_apply "${2:-}" ;;
        revert) cmd_revert ;;
        status) cmd_status ;;
        *)
            cat >&2 <<EOF
Usage: sudo $0 {apply [audio-cores] | revert | status}

  apply [spec]  Constrain system.slice and user.slice to the cores NOT
                listed in <spec> (e.g. "2,3" or "2-5" or "2,4-6"). Effect
                is immediate via 'systemctl daemon-reload'. If <spec> is
                omitted, the script prompts.
  revert        Remove the two drop-ins and daemon-reload back to defaults.
  status        Show host core count, current live AllowedCPUs of
                system.slice and user.slice, and any managed drop-ins.

EXPERIMENTAL — see the header of this script for design notes and the
relationship with isolcpus / nohz_full / rcu_nocbs.
EOF
            exit 2
            ;;
    esac
}

main "$@"
