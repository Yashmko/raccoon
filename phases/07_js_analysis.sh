#!/usr/bin/env bash
# ============================================================================
# Phase 07: JavaScript Analysis
# ============================================================================
# Tool: LinkFinder
# Input:  target domain (recursive mode)
# Output: endpoints.json, endpoints.html
# Deps:   none (runs against domain directly)
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/../lib/common.sh"
phase_init "07_js_analysis"

TARGET=""
RESUME=0
phase_parse_args "$@"
[[ -z "$TARGET" ]] && { echo "ERROR: --target required" >&2; exit 1; }

phase_check_resume
phase_check_enabled

# ------------------------------- TOOL CHECK ----------------------------------
if [[ ! -x "$LINKFINDER" ]]; then
    log_error "$PHASE_NAME" "LinkFinder not found at ${LINKFINDER}"
    phase_finish "skipped" 0 "\"reason\":\"tool_missing\""
    exit 0
fi

# ------------------------------- RUN ----------------------------------------
log_info "$PHASE_NAME" "analyzing JavaScript for ${TARGET}"

OUT_JSON="${PHASE_DIR}/endpoints.json"
OUT_HTML="${PHASE_DIR}/endpoints.html"

LF_TIMEOUT=$(yaml_get "phases.js_analysis.linkfinder.timeout" "10")

# JSON: pipe to stdout (avoids -o flag collision)
retry_with_backoff "$RETRY_MAX" "$RETRY_BASE" "$RETRY_MAX_DELAY" \
    "$LINKFINDER" -d "$TARGET" -o json -t "$LF_TIMEOUT" > "$OUT_JSON" 2>/dev/null

# HTML: use -o flag for file path
retry_with_backoff "$RETRY_MAX" "$RETRY_BASE" "$RETRY_MAX_DELAY" \
    "$LINKFINDER" -d "$TARGET" -o html -o "$OUT_HTML" -t "$LF_TIMEOUT" 2>/dev/null

COUNT=$(safe_wc "$OUT_JSON")
log_info "$PHASE_NAME" "JS endpoint lines: ${COUNT}"

phase_finish "js_endpoints" "$COUNT"
