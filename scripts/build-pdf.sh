#!/bin/bash
#
# build-pdf.sh — render a Markdown guide to a styled PDF.
#
# Usage:
#   scripts/build-pdf.sh [path/to/guide.md] [output.pdf]
#
#   - Argument 1: the Markdown file, relative to the repo root.
#     Default: docs/en/newbie-walkthrough.md
#   - Argument 2: output PDF path. Default: same name/dir as the input,
#     with a .pdf extension.
#
# Uses pandoc + WeasyPrint + docs/pdf.css. pandoc is invoked from the
# Markdown file's own directory so relative image paths (../images/en/...)
# resolve correctly.
#
# Dependencies (Fedora):  sudo dnf install -y pandoc weasyprint
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CSS="${REPO_ROOT}/docs/pdf.css"

REL_INPUT="${1:-docs/en/newbie-walkthrough.md}"
INPUT="${REPO_ROOT}/${REL_INPUT}"

# --- Dependency checks ---------------------------------------------------

_missing=()
command -v pandoc     >/dev/null 2>&1 || _missing+=(pandoc)
command -v weasyprint >/dev/null 2>&1 || _missing+=(weasyprint)
if [[ ${#_missing[@]} -gt 0 ]]; then
    echo "ERROR: missing tool(s): ${_missing[*]}" >&2
    echo "Install with: sudo dnf install -y pandoc weasyprint" >&2
    exit 1
fi

if [[ ! -f "$INPUT" ]]; then
    echo "ERROR: input not found: ${INPUT}" >&2
    exit 1
fi
if [[ ! -f "$CSS" ]]; then
    echo "ERROR: stylesheet not found: ${CSS}" >&2
    exit 1
fi

# --- Output path ---------------------------------------------------------

if [[ -n "${2:-}" ]]; then
    OUTPUT="$2"
    [[ "$OUTPUT" = /* ]] || OUTPUT="${REPO_ROOT}/${OUTPUT}"
else
    OUTPUT="${INPUT%.md}.pdf"
fi

# --- Title: first level-1 heading, stripped of leading "# " --------------

TITLE=$(grep -m1 '^# ' "$INPUT" | sed 's/^# *//')
[[ -n "$TITLE" ]] || TITLE="fedora-audiophile-setup documentation"

# --- Render --------------------------------------------------------------

INPUT_DIR="$(cd "$(dirname "$INPUT")" && pwd)"
INPUT_BASE="$(basename "$INPUT")"

echo "Rendering ${REL_INPUT}"
echo "  title : ${TITLE}"
echo "  css   : ${CSS}"
echo "  output: ${OUTPUT}"

# Run pandoc from the Markdown file's directory so that relative image
# references resolve. resource-path also covers ../images for safety.
(
    cd "$INPUT_DIR"
    pandoc "$INPUT_BASE" \
        --from=gfm \
        --pdf-engine=weasyprint \
        --toc \
        --toc-depth=2 \
        --metadata title="$TITLE" \
        --css="$CSS" \
        --resource-path=".:..:../.." \
        --standalone \
        -o "$OUTPUT"
)

echo "Done: ${OUTPUT}"
