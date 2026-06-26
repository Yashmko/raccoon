#!/usr/bin/env bash
# ============================================================================
# Phase 01: Subdomain Enumeration
# ============================================================================
# Tools: subfinder + crt.sh (supplementary)
# Input:  target domain
# Output: subdomains.txt, subdomains.json, subdomains_crt.txt
# Deps:   none
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/../lib/common.sh"
phase_init "01_subdomains"

TARGET=""
RESUME=0
phase_parse_args "$@"
[[ -z "$TARGET" ]] && { echo "ERROR: --target required" >&2; exit 1; }

phase_check_resume
phase_check_enabled

# ------------------------------- RUN ----------------------------------------
log_info "$PHASE_NAME" "starting subdomain enumeration for ${TARGET}"

OUT_TXT="${PHASE_DIR}/subdomains.txt"
OUT_JSON="${PHASE_DIR}/subdomains.json"
OUT_CRT="${PHASE_DIR}/subdomains_crt.txt"

# subfinder
SUBFINDER_ARGS=(-d "$TARGET" -silent -o "$OUT_TXT" -oJ "$OUT_JSON")
[[ "$(yaml_get 'phases.subdomains.subfinder.all_sources' '0')" -eq 1 ]] && SUBFINDER_ARGS+=(-all)
[[ "$(yaml_get 'phases.subdomains.subfinder.recursive' '0')" -eq 1 ]] && SUBFINDER_ARGS+=(-recursive)
SUBFINDER_ARGS+=(-timeout "$(yaml_get 'phases.subdomains.subfinder.timeout' '30')")

log_info "$PHASE_NAME" "running subfinder..."
retry_with_backoff "$RETRY_MAX" "$RETRY_BASE" "$RETRY_MAX_DELAY" \
    "$SUBFINDER" "${SUBFINDER_ARGS[@]}"
log_info "$PHASE_NAME" "subfinder: $(safe_wc "$OUT_TXT") subdomains"

# crt.sh supplementary
if [[ "$(yaml_get 'phases.subdomains.crtsh.enabled' '1')" -eq 1 ]]; then
    log_info "$PHASE_NAME" "querying crt.sh..."
    curl -s --max-time 30 "https://crt.sh/?q=%25.${TARGET}&output=json" 2>/dev/null \
        | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    names = set()
    for entry in data:
        for name in entry.get('name_value', '').split('\n'):
            name = name.strip().lower()
            if name and name.endswith('.${TARGET}'):
                names.add(name)
    for n in sorted(names):
        print(n)
except: pass
" > "$OUT_CRT" 2>/dev/null || true
    log_info "$PHASE_NAME" "crt.sh: $(safe_wc "$OUT_CRT") subdomains"
fi

# Merge and deduplicate
cat "$OUT_TXT" "$OUT_CRT" 2>/dev/null | sort -u > "${OUT_TXT}.tmp"
mv "${OUT_TXT}.tmp" "$OUT_TXT"

COUNT=$(safe_wc "$OUT_TXT")
log_info "$PHASE_NAME" "total unique subdomains: ${COUNT}"

phase_finish "subdomains" "$COUNT"
