#!/usr/bin/env bash
# ============================================================================
# Phase 04: URL Harvesting (Passive Sources)
# ============================================================================
# Tools: gau + waybackurls
# Input:  target domain
# Output: urls_gau.txt, urls_wayback.txt, urls_all.txt (merged)
# Deps:   none (runs against domain directly)
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/../lib/common.sh"
phase_init "04_urls"

TARGET=""
RESUME=0
phase_parse_args "$@"
[[ -z "$TARGET" ]] && { echo "ERROR: --target required" >&2; exit 1; }

phase_check_resume
phase_check_enabled

# ------------------------------- RUN ----------------------------------------
log_info "$PHASE_NAME" "harvesting URLs for ${TARGET}"

OUT_GAU="${PHASE_DIR}/urls_gau.txt"
OUT_WB="${PHASE_DIR}/urls_wayback.txt"
OUT_ALL="${PHASE_DIR}/urls_all.txt"

# gau
GAU_THREADS=$(yaml_get "phases.urls.gau.threads" "5")
GAU_PROVIDERS=$(yaml_get "phases.urls.gau.providers" "wayback,commoncrawl,otx,urlscan")

rate_limit_wait
log_info "$PHASE_NAME" "running gau (threads=${GAU_THREADS})..."
echo "$TARGET" | retry_with_backoff "$RETRY_MAX" "$RETRY_BASE" "$RETRY_MAX_DELAY" \
    "$GAU" --threads "$GAU_THREADS" --providers "$GAU_PROVIDERS" -o "$OUT_GAU"
log_info "$PHASE_NAME" "gau: $(safe_wc "$OUT_GAU") URLs"

# waybackurls (supplementary)
if [[ "$(yaml_get 'phases.urls.waybackurls.enabled' '1')" -eq 1 ]]; then
    rate_limit_wait
    log_info "$PHASE_NAME" "running waybackurls..."
    echo "$TARGET" | "$WAYBACKURLS" > "$OUT_WB" 2>/dev/null
    log_info "$PHASE_NAME" "waybackurls: $(safe_wc "$OUT_WB") URLs"
fi

# Merge and deduplicate
cat "$OUT_GAU" "$OUT_WB" 2>/dev/null | sort -u > "$OUT_ALL"

COUNT=$(safe_wc "$OUT_ALL")
log_info "$PHASE_NAME" "total unique URLs: ${COUNT}"

phase_finish "urls" "$COUNT"
