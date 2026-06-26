#!/usr/bin/env bash
# ============================================================================
# Phase 05: Parameter Discovery
# ============================================================================
# Tool: arjun
# Input:  urls_all.txt (from Phase 04)
# Output: params.json, params.txt
# Deps:   Phase 04
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/../lib/common.sh"
phase_init "05_params"

TARGET=""
RESUME=0
phase_parse_args "$@"

phase_check_resume
phase_check_enabled

# ------------------------------- INPUT CHECK ---------------------------------
INFILE="${RECON_DIR}/04_urls/urls_all.txt"
require_input "$INFILE" "$PHASE_NAME" || exit 0

# ------------------------------- RUN ----------------------------------------
log_info "$PHASE_NAME" "discovering parameters in $(safe_wc "$INFILE") URLs"

OUT_JSON="${PHASE_DIR}/params.json"
OUT_TXT="${PHASE_DIR}/params.txt"

ARJUN_ARGS=(-i "$INFILE" -oJ "$OUT_JSON" -oT "$OUT_TXT")
ARJUN_ARGS+=(-m "$(yaml_get 'phases.params.arjun.method' 'GET')")
ARJUN_ARGS+=(-t "$(yaml_get 'phases.params.arjun.threads' '5')")
ARJUN_ARGS+=(-T "$(yaml_get 'phases.params.arjun.timeout' '15')")

[[ "$(yaml_get 'phases.params.arjun.passive' '1')" -eq 1 ]] && ARJUN_ARGS+=(--passive)

rate_limit_wait
retry_with_backoff "$RETRY_MAX" "$RETRY_BASE" "$RETRY_MAX_DELAY" \
    "$ARJUN" "${ARJUN_ARGS[@]}"

COUNT=$(safe_wc "$OUT_TXT")
log_info "$PHASE_NAME" "parameters: ${COUNT}"

phase_finish "parameters" "$COUNT"
