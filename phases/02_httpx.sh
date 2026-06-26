#!/usr/bin/env bash
# ============================================================================
# Phase 02: HTTP Probing / Live Host Discovery
# ============================================================================
# Tool: httpx (ProjectDiscovery)
# Input:  subdomains.txt (from Phase 01)
# Output: live_hosts.txt, live_hosts.json
# Deps:   Phase 01
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/../lib/common.sh"
phase_init "02_httpx"

TARGET=""
RESUME=0
phase_parse_args "$@"

phase_check_resume
phase_check_enabled

# ------------------------------- INPUT CHECK ---------------------------------
INFILE="${RECON_DIR}/01_subdomains/subdomains.txt"
require_input "$INFILE" "$PHASE_NAME" || exit 0

# ------------------------------- RUN ----------------------------------------
log_info "$PHASE_NAME" "probing $(safe_wc "$INFILE") subdomains"

OUT_JSON="${PHASE_DIR}/live_hosts.json"
OUT_TXT="${PHASE_DIR}/live_hosts.txt"

HTTPX_ARGS=(-l "$INFILE" -silent -j -o "$OUT_JSON")
[[ "$(yaml_get 'phases.httpx.probes.status_code' '1')" -eq 1 ]]    && HTTPX_ARGS+=(-sc)
[[ "$(yaml_get 'phases.httpx.probes.content_length' '1')" -eq 1 ]] && HTTPX_ARGS+=(-cl)
[[ "$(yaml_get 'phases.httpx.probes.content_type' '1')" -eq 1 ]]   && HTTPX_ARGS+=(-ct)
[[ "$(yaml_get 'phases.httpx.probes.title' '1')" -eq 1 ]]          && HTTPX_ARGS+=(-title)
[[ "$(yaml_get 'phases.httpx.probes.tech_detect' '1')" -eq 1 ]]    && HTTPX_ARGS+=(-td)
[[ "$(yaml_get 'phases.httpx.probes.ip' '1')" -eq 1 ]]             && HTTPX_ARGS+=(-ip)
[[ "$(yaml_get 'phases.httpx.probes.cname' '1')" -eq 1 ]]          && HTTPX_ARGS+=(-cname)
[[ "$(yaml_get 'phases.httpx.probes.asn' '1')" -eq 1 ]]            && HTTPX_ARGS+=(-asn)
[[ "$(yaml_get 'phases.httpx.probes.cdn' '1')" -eq 1 ]]            && HTTPX_ARGS+=(-cdn)
[[ "$(yaml_get 'phases.httpx.probes.probe' '1')" -eq 1 ]]          && HTTPX_ARGS+=(-probe)

HTTPX_ARGS+=(-timeout "$(yaml_get 'phases.httpx.timeout' '10')")
HTTPX_ARGS+=(-threads "$(yaml_get 'phases.httpx.threads' '50')")

rate_limit_wait
retry_with_backoff "$RETRY_MAX" "$RETRY_BASE" "$RETRY_MAX_DELAY" \
    "$HTTPX" "${HTTPX_ARGS[@]}"

# Extract plain URLs from JSON for downstream tools
python3 -c "
import json
with open('${OUT_JSON}') as f:
    for line in f:
        try:
            obj = json.loads(line)
            print(obj.get('url', obj.get('input', '')))
        except: pass
" > "$OUT_TXT" 2>/dev/null

COUNT=$(safe_wc "$OUT_TXT")
log_info "$PHASE_NAME" "live hosts: ${COUNT}"

phase_finish "live_hosts" "$COUNT"
