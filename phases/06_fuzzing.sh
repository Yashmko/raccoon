#!/usr/bin/env bash
# ============================================================================
# Phase 06: Directory / Path Fuzzing
# ============================================================================
# Tool: ffuf
# Input:  target domain + wordlist
# Output: ffuf_results.json
# Deps:   none (requires wordlist in config)
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/../lib/common.sh"
phase_init "06_fuzzing"

TARGET=""
RESUME=0
phase_parse_args "$@"

phase_check_resume
phase_check_enabled

# ------------------------------- WORDLIST CHECK -----------------------------
WORDLIST=$(yaml_get "phases.fuzzing.wordlist" "")
if [[ -z "$WORDLIST" ]]; then
    log_warn "$PHASE_NAME" "SKIP: no wordlist configured"
    phase_finish "skipped" 0 "\"reason\":\"no_wordlist\""
    exit 0
fi
if [[ ! -f "$WORDLIST" ]]; then
    log_warn "$PHASE_NAME" "SKIP: wordlist not found: ${WORDLIST}"
    phase_finish "skipped" 0 "\"reason\":\"wordlist_missing\""
    exit 0
fi

# ------------------------------- RUN ----------------------------------------
log_info "$PHASE_NAME" "fuzzing ${TARGET} with $(wc -l < "$WORDLIST") words"

OUT="${PHASE_DIR}/ffuf_results.json"

FFUF_ARGS=(
    -u "https://${TARGET}/FUZZ"
    -w "$WORDLIST"
    -o "$OUT"
    -of json
    -mc "$(yaml_get 'phases.fuzzing.ffuf.match_codes' '200,301,302,403,405,500')"
    -t "$(yaml_get 'phases.fuzzing.ffuf.threads' '40')"
    -timeout "$(yaml_get 'phases.fuzzing.ffuf.timeout' '10')"
)

FFUF_RATE=$(yaml_get "phases.fuzzing.ffuf.rate" "0")
[[ "$FFUF_RATE" -gt 0 ]] && FFUF_ARGS+=(-rate "$FFUF_RATE")
[[ "$(yaml_get 'phases.fuzzing.ffuf.auto_calibrate' '0')" -eq 1 ]] && FFUF_ARGS+=(-ac)

rate_limit_wait
retry_with_backoff "$RETRY_MAX" "$RETRY_BASE" "$RETRY_MAX_DELAY" \
    "$FFUF" "${FFUF_ARGS[@]}"

COUNT=$(python3 -c "
import json
try:
    with open('${OUT}') as f:
        print(len(json.load(f).get('results', [])))
except: print(0)
" 2>/dev/null)

log_info "$PHASE_NAME" "fuzz results: ${COUNT}"

phase_finish "fuzz_results" "$COUNT"
