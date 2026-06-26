#!/usr/bin/env bash
# ============================================================================
# Phase 03: Endpoint Discovery (Crawling)
# ============================================================================
# Tool: katana
# Input:  live_hosts.txt (from Phase 02)
# Output: endpoints.txt
# Deps:   Phase 02
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/../lib/common.sh"
phase_init "03_endpoints"

TARGET=""
RESUME=0
phase_parse_args "$@"

phase_check_resume
phase_check_enabled

# ------------------------------- INPUT CHECK ---------------------------------
INFILE="${RECON_DIR}/02_live_hosts/live_hosts.txt"
require_input "$INFILE" "$PHASE_NAME" || exit 0

# ------------------------------- RUN ----------------------------------------
log_info "$PHASE_NAME" "crawling $(safe_wc "$INFILE") hosts"

OUT="${PHASE_DIR}/endpoints.txt"

KATANA_ARGS=(-list "$INFILE" -silent -o "$OUT")
KATANA_ARGS+=(-d "$(yaml_get 'phases.endpoints.katana.depth' '3')")
KATANA_ARGS+=(-timeout "$(yaml_get 'phases.endpoints.katana.timeout' '10')")

[[ "$(yaml_get 'phases.endpoints.katana.js_crawl' '1')" -eq 1 ]] && KATANA_ARGS+=(-jc)
[[ "$(yaml_get 'phases.endpoints.katana.headless' '0')" -eq 1 ]] && KATANA_ARGS+=(-hl)

DURATION=$(yaml_get "phases.endpoints.katana.crawl_duration" "")
[[ -n "$DURATION" ]] && KATANA_ARGS+=(-ct "$DURATION")

MAX_SIZE=$(yaml_get "phases.endpoints.katana.max_response_size" "4194304")
KATANA_ARGS+=(-mrs "$MAX_SIZE")

rate_limit_wait
retry_with_backoff "$RETRY_MAX" "$RETRY_BASE" "$RETRY_MAX_DELAY" \
    "$KATANA" "${KATANA_ARGS[@]}"

COUNT=$(safe_wc "$OUT")
log_info "$PHASE_NAME" "endpoints: ${COUNT}"

phase_finish "endpoints" "$COUNT"
