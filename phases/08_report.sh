#!/usr/bin/env bash
# ============================================================================
# Phase 08: Report Generation
# ============================================================================
# Aggregates all phase summaries into a structured markdown report.
# Input:  all phase output directories
# Output: final_report_YYYYMMDD_HHMMSS.md
# Deps:   all previous phases (independent of tool availability)
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/../lib/common.sh"
phase_init "08_report"

RESUME=0
phase_parse_args "$@"

phase_check_enabled

# ------------------------------- RUN ----------------------------------------
log_info "$PHASE_NAME" "generating report"

TARGET=$(yaml_get "global.target" "")
REPORT_TS=$(date +"%Y%m%d_%H%M%S")
REPORT="${PHASE_DIR}/final_report_${REPORT_TS}.md"

# Read counts from summary.json files or output files
read_count() {
    local summary="$1/summary.json"
    local file="$2"
    if [[ -f "$summary" ]]; then
        python3 -c "import json; print(json.load(open('${summary}')).get('count', 0))" 2>/dev/null || echo 0
    elif [[ -f "$file" ]]; then
        safe_wc "$file"
    else
        echo 0
    fi
}

S01=$(read_count "${RECON_DIR}/01_subdomains" "${RECON_DIR}/01_subdomains/subdomains.txt")
S02=$(read_count "${RECON_DIR}/02_live_hosts" "${RECON_DIR}/02_live_hosts/live_hosts.txt")
S03=$(read_count "${RECON_DIR}/03_endpoints" "${RECON_DIR}/03_endpoints/endpoints.txt")
S04=$(read_count "${RECON_DIR}/04_urls" "${RECON_DIR}/04_urls/urls_all.txt")
S05=$(read_count "${RECON_DIR}/05_params" "${RECON_DIR}/05_params/params.txt")
S06=$(read_count "${RECON_DIR}/06_fuzzing" "${RECON_DIR}/06_fuzzing/ffuf_results.json")
S07=$(read_count "${RECON_DIR}/07_js_analysis" "${RECON_DIR}/07_js_analysis/endpoints.json")

# Checkpoint status
CP_DATA=""
if [[ -f "${RECON_DIR}/08_reports/.checkpoint.json" ]]; then
    CP_DATA=$(python3 -c "
import json
with open('${RECON_DIR}/08_reports/.checkpoint.json') as f:
    data = json.load(f)
for phase, info in sorted(data.get('completed', {}).items()):
    print(f\"| {phase} | {info.get('status','ok')} | {info.get('finished_at','N/A')} |\")
" 2>/dev/null || echo "")
fi

cat > "$REPORT" <<EOF
# Recon Report: ${TARGET}

**Generated:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")
**Pipeline:** recon-framework v2.0

## Summary

| Phase | Metric | Count |
|-------|--------|-------|
| 01 Subdomains | Subdomains discovered | ${S01} |
| 02 HTTP Probing | Live hosts | ${S02} |
| 03 Endpoints | Endpoints crawled | ${S03} |
| 04 URLs | URLs collected | ${S04} |
| 05 Parameters | Parameters found | ${S05} |
| 06 Fuzzing | Fuzz results | ${S06} |
| 07 JS Analysis | LinkFinder endpoints | ${S07} |

## Checkpoint Status

| Phase | Status | Completed At |
|-------|--------|-------------|
${CP_DATA}

## Output Structure

\`\`\`
${RECON_DIR}/
├── 01_subdomains/    subdomains.txt, subdomains.json
├── 02_live_hosts/    live_hosts.txt, live_hosts.json
├── 03_endpoints/     endpoints.txt
├── 04_urls/          urls_gau.txt, urls_wayback.txt, urls_all.txt
├── 05_params/        params.json, params.txt
├── 06_fuzzing/       ffuf_results.json
├── 07_js_analysis/   endpoints.json, endpoints.html
└── 08_reports/       this report, pipeline.log, .checkpoint.json
\`\`\`
EOF

log_info "$PHASE_NAME" "report generated: ${REPORT}"
checkpoint_set "$PHASE_NAME"
