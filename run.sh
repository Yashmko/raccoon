#!/usr/bin/env bash
# ============================================================================
# run.sh — Recon Pipeline Orchestrator
# ============================================================================
# Entry point for the modular recon pipeline.
# Runs phases in dependency order with checkpoint/resume support.
#
# Usage:
#   ./run.sh -t example.com                     # run all enabled phases
#   ./run.sh -t example.com -p 1,2,4            # run specific phases
#   ./run.sh -t example.com --resume             # resume from last checkpoint
#   ./run.sh -c /path/to/config.yaml -t example.com  # custom config
#   ./run.sh --reset                             # clear checkpoints, start fresh
#
# Each phase is independently executable:
#   ./phases/01_subdomains.sh --target example.com --config config.yaml
# ============================================================================

set -uo pipefail

PIPELINE_DIR="$(cd "$(dirname "$0")" && pwd)"
export PIPELINE_DIR

# ------------------------------- PHASE DEPENDENCIES -------------------------
# Defines which phases depend on which. Used for ordering and validation.
declare -A PHASE_DEPS=(
    [01_subdomains]=""
    [02_httpx]="01_subdomains"
    [03_endpoints]="02_httpx"
    [04_urls]=""
    [05_params]="04_urls"
    [06_fuzzing]=""
    [07_js_analysis]=""
    [08_report]="01_subdomains 02_httpx 03_endpoints 04_urls 05_params 06_fuzzing 07_js_analysis"
)

# Phase execution order (topological sort — fixed)
PHASE_ORDER=(
    01_subdomains
    04_urls
    02_httpx
    03_endpoints
    05_params
    06_fuzzing
    07_js_analysis
    08_report
)

# ------------------------------- USAGE --------------------------------------
usage() {
    cat <<EOF
Recon Pipeline Orchestrator

Usage: $0 [OPTIONS]

Required:
  -t, --target DOMAIN       Target domain (e.g., example.com)

Optional:
  -c, --config FILE         Config file (default: ./config.yaml)
  -p, --phases LIST         Comma-separated phase numbers (default: all)
                            e.g., -p 1,2,4 or -p 1-5
  --resume                  Resume from last checkpoint (skip completed phases)
  --reset                   Clear checkpoints and start fresh
  --list                    List all phases and their status
  -h, --help                Show this help

Phase Numbers:
  1 = subdomains    5 = params
  2 = httpx         6 = fuzzing
  3 = endpoints     7 = js_analysis
  4 = urls          8 = report

Examples:
  $0 -t example.com
  $0 -t example.com -p 1,2,4
  $0 -t example.com --resume
  $0 --list -c config.yaml
EOF
    exit 0
}

# ------------------------------- SIGNAL HANDLING ----------------------------
RUNNING=1
trap 'echo ""; echo "[INTERRUPTED] Received SIGINT. Cleaning up..."; RUNNING=0; exit 130' INT
trap 'echo "[TERM] Received SIGTERM. Cleaning up..."; RUNNING=0; exit 143' TERM

# ------------------------------- UTILITIES ----------------------------------
# Source common.sh for logging and utilities
. "${PIPELINE_DIR}/lib/common.sh"

# Parse phase list flag: "1,2,4" or "1-5" or "1,2-4,7"
parse_phase_list() {
    local input="$1"
    local result=()
    IFS=',' read -ra items <<< "$input"
    for item in "${items[@]}"; do
        if [[ "$item" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            for ((i=${BASH_REMATCH[1]}; i<=${BASH_REMATCH[2]}; i++)); do
                result+=("$i")
            done
        elif [[ "$item" =~ ^[0-9]+$ ]]; then
            result+=("$item")
        fi
    done
    echo "${result[@]}"
}

# Resolve phase number to phase directory name
phase_num_to_name() {
    local num="$1"
    for name in "${PHASE_ORDER[@]}"; do
        if [[ "$name" == "${num}_"* ]]; then
            echo "$name"
            return 0
        fi
    done
    return 1
}

# Check if a phase number is in the enabled set
phase_in_set() {
    local phase_num="$1"
    shift
    local enabled_set=("$@")
    for e in "${enabled_set[@]}"; do
        [[ "$e" == "$phase_num" ]] && return 0
    done
    return 1
}

# ------------------------------- LIST PHASES -------------------------------
list_phases() {
    local config="${CONFIG_FILE:-${PIPELINE_DIR}/config.yaml}"
    export CONFIG_FILE="$config"
    RECON_DIR=$(yaml_get "global.output_dir" "./recon")
    RECON_DIR="${PIPELINE_DIR}/${RECON_DIR#./}"
    checkpoint_init 2>/dev/null

    echo "Phase  Name              Status"
    echo "─────  ────              ──────"
    for phase_name in "${PHASE_ORDER[@]}"; do
        local num="${phase_name%%_*}"
        local status="pending"
        local enabled_key="phases.${phase_name#*_}.enabled"
        local enabled_val
        enabled_val=$(yaml_get "$enabled_key" "1")

        if [[ "$enabled_val" -eq 0 ]]; then
            status="disabled"
        elif checkpoint_has "$phase_name" 2>/dev/null; then
            status="done"
        fi

        printf "  %s    %-16s  %s\n" "$num" "$phase_name" "$status"
    done
}

# ------------------------------- PARSE ARGS ---------------------------------
CONFIG_FILE="${PIPELINE_DIR}/config.yaml"
TARGET=""
ENABLED_PHASES="all"
RESUME=0
RESET=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--target)   TARGET="$2"; shift 2 ;;
        -c|--config)   CONFIG_FILE="$2"; shift 2 ;;
        -p|--phases)   ENABLED_PHASES="$2"; shift 2 ;;
        --resume)      RESUME=1; shift ;;
        --reset)       RESET=1; shift ;;
        --list)        list_phases; exit 0 ;;
        -h|--help)     usage ;;
        *)             echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ------------------------------- VALIDATE -----------------------------------
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config file not found: ${CONFIG_FILE}" >&2
    exit 1
fi

export CONFIG_FILE

# Override target from config if not provided on CLI
if [[ -z "$TARGET" ]]; then
    TARGET=$(yaml_get "global.target" "")
fi
if [[ -z "$TARGET" ]]; then
    echo "ERROR: Target domain required (-t flag or global.target in config)" >&2
    exit 1
fi

# Set target in config at runtime (for phases reading from config)
export PIPELINE_TARGET="$TARGET"

# ------------------------------- SETUP --------------------------------------
RECON_DIR=$(yaml_get "global.output_dir" "./recon")
RECON_DIR="${PIPELINE_DIR}/${RECON_DIR#./}"
export RECON_DIR

mkdir -p "${RECON_DIR}"/{01_subdomains,02_live_hosts,03_endpoints,04_urls,05_params,06_fuzzing,07_js_analysis,08_reports}

_LOG_FILE=$(yaml_get "global.log_file" "${RECON_DIR}/08_reports/pipeline.log")
mkdir -p "$(dirname "$_LOG_FILE")"
export _LOG_FILE

checkpoint_init

# Handle --reset
if [[ "$RESET" -eq 1 ]]; then
    checkpoint_clear
    echo "Checkpoints cleared."
    exit 0
fi

# ------------------------------- LOGO ---------------------------------------
log/plain "============================================="
log/plain "  Recon Pipeline v2.0"
log/plain "  Target: ${TARGET}"
log/plain "  Config: ${CONFIG_FILE}"
log/plain "============================================="

# ------------------------------- TOOL CHECK ---------------------------------
log/plain "Checking tools..."
TOOLS_OK=1
for label in SUBFINDER HTTPX KATANA GAU WAYBACKURLS FFUF; do
    path="${!label}"
    if [[ -x "$path" ]]; then
        log/plain "  [OK]   ${label}"
    else
        log/plain "  [MISS] ${label} -> ${path}"
        TOOLS_OK=0
    fi
done
if command -v arjun &>/dev/null; then
    log/plain "  [OK]   ARJUN -> $(command -v arjun)"
else
    log/plain "  [MISS] ARJUN"
    TOOLS_OK=0
fi
LINKFINDER="${PIPELINE_DIR}/$(yaml_get "tools.linkfinder" "./LinkFinder/linkfinder.py")"
if [[ -x "$LINKFINDER" ]]; then
    log/plain "  [OK]   LINKFINDER"
else
    log/plain "  [MISS] LINKFINDER"
    TOOLS_OK=0
fi
[[ "$TOOLS_OK" -eq 0 ]] && log/plain "[WARNING] Some tools missing."

# ------------------------------- RESOLVE PHASES -----------------------------
# Build list of phases to run
if [[ "$ENABLED_PHASES" == "all" ]]; then
    PHASES_TO_RUN=("${PHASE_ORDER[@]}")
else
    PHASES_TO_RUN=()
    while IFS= read -r num; do
        name=$(phase_num_to_name "$num")
        if [[ -n "$name" ]]; then
            PHASES_TO_RUN+=("$name")
        else
            echo "WARNING: Unknown phase number: ${num}" >&2
        fi
    done <<< "$(parse_phase_list "$ENABLED_PHASES")"
fi

# Filter: only enabled phases from config
FILTERED_PHASES=()
for phase_name in "${PHASES_TO_RUN[@]}"; do
    enabled_key="phases.${phase_name#*_}.enabled"
    enabled_val=$(yaml_get "$enabled_key" "1")
    if [[ "$enabled_val" -eq 1 ]]; then
        FILTERED_PHASES+=("$phase_name")
    else
        log/plain "  [SKIP] ${phase_name} (disabled in config)"
    fi
done

log/plain ""
log/plain "Phases to run: ${#FILTERED_PHASES[@]}"
for p in "${FILTERED_PHASES[@]}"; do
    log/plain "  - ${p}"
done
log/plain ""

# ------------------------------- EXECUTE PHASES -----------------------------
COMPLETED=0
FAILED=0
SKIPPED=0
START_TIME=$(date +%s)

for phase_name in "${FILTERED_PHASES[@]}"; do
    if [[ "$RUNNING" -eq 0 ]]; then
        log/plain "[INTERRUPTED] Pipeline stopped."
        break
    fi

    phase_num="${phase_name%%_*}"
    phase_script="${PIPELINE_DIR}/phases/${phase_name}.sh"

    if [[ ! -x "$phase_script" ]]; then
        log/plain "[ERROR] Phase script not found: ${phase_script}"
        FAILED=$((FAILED + 1))
        continue
    fi

    log/plain "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log/plain "Phase ${phase_num}: ${phase_name#*_}"
    log/plain "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    PHASE_START=$(date +%s)

    # Run phase with: --target, --config, optionally --resume
    PHASE_ARGS=(--target "$TARGET" --config "$CONFIG_FILE")
    [[ "$RESUME" -eq 1 ]] && PHASE_ARGS+=(--resume)

    if bash "$phase_script" "${PHASE_ARGS[@]}"; then
        PHASE_END=$(date +%s)
        PHASE_ELAPSED=$((PHASE_END - PHASE_START))
        log/plain "[OK]   ${phase_name} completed in ${PHASE_ELAPSED}s"
        COMPLETED=$((COMPLETED + 1))
    else
        PHASE_END=$(date +%s)
        PHASE_ELAPSED=$((PHASE_END - PHASE_START))
        log/plain "[FAIL] ${phase_name} failed after ${PHASE_ELAPSED}s"
        FAILED=$((FAILED + 1))
    fi
done

# ------------------------------- FINAL SUMMARY ------------------------------
END_TIME=$(date +%s)
TOTAL_ELAPSED=$((END_TIME - START_TIME))

log/plain ""
log/plain "============================================="
log/plain "  Pipeline Complete"
log/plain "  Elapsed: ${TOTAL_ELAPSED}s"
log/plain "  Completed: ${COMPLETED}"
log/plain "  Failed: ${FAILED}"
log/plain "  Output: ${RECON_DIR}"
log/plain "============================================="

exit $FAILED
