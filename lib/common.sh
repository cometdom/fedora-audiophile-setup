#!/bin/bash
#
# lib/common.sh — shared helpers for fedora-audiophile-setup modules.
#
# Provides:
#   - log_info / log_warn / log_error / log_step
#   - ask_yes_no
#   - has_package, package_install
#   - run_cmd        (honors DRY_RUN)
#   - init_log
#   - list_modules
#   - run_all_modules / run_single_module
#

LOG_DIR="/var/log/audiophile-setup"
LOG_FILE=""

# ANSI colors
readonly C_RESET='\033[0m'
readonly C_RED='\033[0;31m'
readonly C_YELLOW='\033[0;33m'
readonly C_GREEN='\033[0;32m'
readonly C_BLUE='\033[0;34m'
readonly C_BOLD='\033[1m'

# --- Logging ---------------------------------------------------------------

init_log() {
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/$(date +%Y%m%d-%H%M%S).log"
    : > "$LOG_FILE"
    chmod 600 "$LOG_FILE"
}

_log() {
    local color="$1" prefix="$2"; shift 2
    local msg="$*"
    local ts; ts=$(date '+%H:%M:%S')
    echo -e "${color}[${ts}] ${prefix}${C_RESET} ${msg}"
    if [[ -n "${LOG_FILE:-}" ]]; then
        echo "[$(date -Iseconds)] ${prefix} ${msg}" >> "$LOG_FILE"
    fi
}

log_info()  { _log "$C_BLUE"   "INFO " "$@"; }
log_warn()  { _log "$C_YELLOW" "WARN " "$@"; }
log_error() { _log "$C_RED"    "ERROR" "$@"; }
log_step()  { _log "$C_GREEN"  "STEP " "$@"; }

# --- Prompts ---------------------------------------------------------------

# ask_yes_no "Question?" [default=Y|N]  — sets REPLY=0 (yes) or 1 (no)
ask_yes_no() {
    local prompt="$1"
    local default="${2:-Y}"
    local hint
    [[ "$default" == "Y" ]] && hint="[Y/n]" || hint="[y/N]"

    while true; do
        read -r -p "$prompt $hint " answer
        answer="${answer:-$default}"
        case "$answer" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo])     return 1 ;;
            *) echo "Please answer yes or no." ;;
        esac
    done
}

# --- System helpers --------------------------------------------------------

has_package() {
    rpm -q "$1" >/dev/null 2>&1
}

is_service_enabled() {
    systemctl is-enabled --quiet "$1" 2>/dev/null
}

is_service_active() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

# --- Command execution with DRY_RUN support --------------------------------

# run_cmd <cmd...> — execute (or echo if DRY_RUN=1) a command, logging stdout/stderr.
run_cmd() {
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_info "DRY-RUN: would execute: $*"
        return 0
    fi
    log_info "Executing: $*"
    "$@" 2>&1 | tee -a "$LOG_FILE"
    return "${PIPESTATUS[0]}"
}

# --- Module discovery ------------------------------------------------------

# list_modules — print module names in execution order, one per line.
# Module file format: modules/NN-name.sh  → name printed as "name".
list_modules() {
    find "$MODULES_DIR" -maxdepth 1 -name '[0-9][0-9]-*.sh' -type f 2>/dev/null \
        | sort \
        | sed -E 's|.*/[0-9]+-([^/]+)\.sh|\1|'
}

# resolve_module_path <short-name> — print full path or empty if not found.
resolve_module_path() {
    local name="$1"
    find "$MODULES_DIR" -maxdepth 1 -name "[0-9][0-9]-${name}.sh" -type f 2>/dev/null \
        | head -1
}

run_all_modules() {
    # Read the list FIRST into an array, then iterate with `for`. Do NOT use
    # `while IFS= read -r module; do ... done < <(list_modules)` — that
    # redirects stdin of the whole loop body (and every module sourced from
    # it) to the list_modules pipe, which silently steals input from any
    # interactive `read` inside a module. Bug fixed: previously, ask_yes_no
    # inside a module consumed the names of the remaining modules as its
    # "answers", looping 10x on "Please answer yes or no." and prematurely
    # ending the run.
    local -a modules=()
    local m
    while IFS= read -r m; do modules+=("$m"); done < <(list_modules)

    local count=${#modules[@]}
    if [[ "$count" -eq 0 ]]; then
        log_warn "No modules found in $MODULES_DIR — nothing to do."
        return 0
    fi

    log_step "Running $count module(s) in order."
    local module path
    for module in "${modules[@]}"; do
        path=$(resolve_module_path "$module")
        log_step "→ $module"
        # shellcheck source=/dev/null
        source "$path"
    done
}

run_single_module() {
    local name="$1"
    local path
    path=$(resolve_module_path "$name")

    if [[ -z "$path" ]]; then
        log_error "Module not found: $name"
        log_info "Available modules:"
        list_modules | sed 's/^/  /'
        exit 1
    fi

    log_step "Running single module: $name"
    # shellcheck source=/dev/null
    source "$path"
}

# module_description <path> — print the short description from the module's
# header line `# NN-name — description`. Empty if the file has no match.
module_description() {
    local path="$1"
    [[ -r "$path" ]] || return 0
    awk '
        /^# [0-9]+-[a-z0-9-]+ — / {
            sub(/^# [0-9]+-[a-z0-9-]+ — /, "");
            print;
            exit;
        }
    ' "$path"
}

# show_menu_and_dispatch — interactive numbered menu. Option 1 runs all
# modules in order (default on Enter); options 2..N run one module
# standalone; the last option exits cleanly.
show_menu_and_dispatch() {
    local -a names=()
    while IFS= read -r m; do names+=("$m"); done < <(list_modules)
    if [[ ${#names[@]} -eq 0 ]]; then
        log_warn "No modules found in $MODULES_DIR — nothing to do."
        return 0
    fi

    # Width of the longest module name, for visual alignment.
    local maxw=12  # at least as wide as "Full install"
    local n
    for n in "${names[@]}"; do
        (( ${#n} > maxw )) && maxw=${#n}
    done

    echo
    echo "What do you want to do?"
    echo
    printf "  %2d) %-*s   %s\n" 1 "$maxw" "Full install" "all modules in order (recommended)"
    local i=2 path desc
    for n in "${names[@]}"; do
        path=$(resolve_module_path "$n")
        desc=$(module_description "$path")
        printf "  %2d) %-*s — %s\n" "$i" "$maxw" "$n" "${desc:-(no description)}"
        i=$((i+1))
    done
    local exit_idx=$i
    printf "  %2d) %-*s\n" "$exit_idx" "$maxw" "Exit"
    echo

    local choice
    while true; do
        read -r -p "Choose [1]: " choice
        choice="${choice:-1}"
        if [[ "$choice" == "1" ]]; then
            run_all_modules
            return 0
        elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 2 && choice < exit_idx )); then
            run_single_module "${names[$((choice-2))]}"
            return 0
        elif [[ "$choice" == "$exit_idx" ]]; then
            log_info "Bye."
            exit 0
        fi
        echo "Invalid choice. Enter a number between 1 and ${exit_idx}."
    done
}
