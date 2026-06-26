#!/usr/bin/env bash
# ============================================================================
# lib/common.sh — Shared utilities for the recon pipeline
# ============================================================================
# Source this file from phase scripts:
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   . "${SCRIPT_DIR}/../lib/common.sh"
# ============================================================================

set -uo pipefail

# ------------------------------- GLOBALS ------------------------------------
PIPELINE_DIR="${PIPELINE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONFIG_FILE="${CONFIG_FILE:-${PIPELINE_DIR}/config.yaml}"
RECON_DIR=""
PHASE_NAME=""
PHASE_DIR=""
_LOG_FILE=""
_CHECKPOINT_FILE=""

# ------------------------------- YAML PARSER --------------------------------
# Lightweight YAML value extractor. Handles flat, 2-level, and 3-level keys.
# Usage: yaml_get "global.target" or yaml_get "phases.subdomains.subfinder.all_sources"
#
# WHY awk uses $0 directly instead of modifying $1:
#   In GNU awk, modifying $1 via gsub() reconstructs $0 from fields using OFS
#   (default: space). The line "global:" becomes "global" in $0, destroying the
#   colon. The regex /^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*:/ then fails to match.
#   Fix: extract keys from $0 via sub() which preserves the original line.
yaml_get() {
    local key="$1"
    local default="${2:-}"

    # Single awk pass builds full dotted path per line via indent stack.
    # Handles arbitrary nesting depth (2, 3, 4+ levels) without separate branches.
    # CRITICAL: Never assign $0 to a variable — awk reconstructs $0 from fields
    # using OFS (space), destroying YAML syntax. All key extraction uses sub() on
    # fresh local variables.
    local value
    value=$(awk -v target="$key" '
        function extract_key(_k) {
            _k = $0
            sub(/^[[:space:]]+/, "", _k)
            sub(/:.*/, "", _k)
            return _k
        }
        function indent_depth(_s) {
            _s = $0
            gsub(/[^ ].*/, "", _s)
            return length(_s)
        }
        function extract_value(_v) {
            _v = $0
            sub(/^[[:space:]]+/, "", _v)
            sub(/^[^:]+:[[:space:]]*/, "", _v)
            sub(/#.*$/, "", _v)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", _v)
            sub(/^"/, "", _v)
            sub(/"$/, "", _v)
            sub(/^'\''/, "", _v)
            sub(/'\''$/, "", _v)
            if (_v == "true") _v = "1"
            else if (_v == "false") _v = "0"
            return _v
        }
        {
            d = indent_depth()
            # Root-level key (no indent)
            if (d == 0 && /^[a-zA-Z_][a-zA-Z0-9_]*:/) {
                depth = 1
                path[1] = extract_key()
                next
            }
            # Child key (indented)
            if (d > 0 && /^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*:/) {
                # Pop stack to current indent level
                while (depth > 0 && indent[depth] >= d) depth--
                depth++
                indent[depth] = d
                path[depth] = extract_key()
                # Build full dotted path
                full = path[1]
                for (i = 2; i <= depth; i++) full = full "." path[i]
                if (full == target) {
                    val = extract_value()
                    if (val != "") print val
                }
            }
        }
    ' "$CONFIG_FILE" 2>/dev/null)

    if [[ -n "$value" ]]; then
        echo "$value"
    else
        echo "$default"
    fi
}

# ------------------------------- JSON ESCAPE --------------------------------
# Escape a string for safe inclusion in JSON values.
# Replaces: \ -> \\, " -> \", tab -> \t, newline -> \n
_json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n/g'
}

# ------------------------------- LOGGING ------------------------------------
# Structured JSON logging. Writes to stdout + log file.
# Usage: log_info "phase_name" "message"
#        log_error "phase_name" "message"
#        log_debug "phase_name" "message"
_log() {
    local level="$1"
    local phase="$2"
    local msg="$3"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local log_level
    log_level=$(yaml_get "global.log_level" "info")

    # Level filter
    case "$log_level" in
        debug) ;;
        info)  [[ "$level" == "DEBUG" ]] && return 0 ;;
        warn)  [[ "$level" == "DEBUG" || "$level" == "INFO" ]] && return 0 ;;
        error) [[ "$level" != "ERROR" ]] && return 0 ;;
    esac

    # JSON log line — escape special characters to prevent malformed JSON
    local safe_phase safe_msg
    safe_phase=$(_json_escape "$phase")
    safe_msg=$(_json_escape "$msg")
    local json="{\"ts\":\"${ts}\",\"level\":\"${level}\",\"phase\":\"${safe_phase}\",\"msg\":\"${safe_msg}\"}"
    echo "$json" | tee -a "$_LOG_FILE" 2>/dev/null || echo "$json"
}

log_info()  { _log "INFO"  "$1" "$2"; }
log_error() { _log "ERROR" "$1" "$2"; }
log_debug() { _log "DEBUG" "$1" "$2"; }
log_warn()  { _log "WARN"  "$1" "$2"; }

# Plain-text log (for human-readable output during execution)
log/plain() {
    local ts
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[${ts}] $*" | tee -a "$_LOG_FILE" 2>/dev/null || echo "[${ts}] $*"
}

# ------------------------------- CHECKPOINT ---------------------------------
# Resume/checkpoint system. Tracks completed phases.
# Uses flock for atomic locking to prevent concurrent corruption.
# Usage: checkpoint_init
#        checkpoint_set "phase_name"
#        checkpoint_has "phase_name"
#        checkpoint_clear

checkpoint_init() {
    _CHECKPOINT_FILE="${RECON_DIR}/08_reports/.checkpoint.json"
    if [[ ! -f "$_CHECKPOINT_FILE" ]]; then
        echo '{"completed":{}}' > "$_CHECKPOINT_FILE"
    fi
}

checkpoint_set() {
    local phase="$1"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    # Use sys.argv instead of string interpolation to prevent injection
    (
        flock -w 5 200 || { log_error "$phase" "checkpoint: could not acquire lock"; return 1; }
        python3 -c "
import json, sys
phase, ts, path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, 'r') as f:
    data = json.load(f)
data['completed'][phase] = {'finished_at': ts, 'status': 'ok'}
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
" "$phase" "$ts" "$_CHECKPOINT_FILE" 2>/dev/null
    ) 200>"${_CHECKPOINT_FILE}.lock"
    log_info "$phase" "checkpoint set"
}

checkpoint_has() {
    local phase="$1"
    # Use sys.argv instead of string interpolation to prevent injection
    (
        flock -w 5 200 || return 1
        python3 -c "
import json, sys
phase, path = sys.argv[1], sys.argv[2]
with open(path, 'r') as f:
    data = json.load(f)
sys.exit(0 if phase in data.get('completed', {}) else 1)
" "$phase" "$_CHECKPOINT_FILE" 2>/dev/null
    ) 200>"${_CHECKPOINT_FILE}.lock"
}

checkpoint_clear() {
    (
        flock -w 5 200 || return 1
        echo '{"completed":{}}' > "$_CHECKPOINT_FILE" 2>/dev/null
    ) 200>"${_CHECKPOINT_FILE}.lock"
}

# ------------------------------- RETRY WITH BACKOFF -------------------------
# Usage: retry_with_backoff <max_attempts> <base_delay> <max_delay> <command...>
#
# WHY the exit code capture changed:
#   Original: if "$@"; then return 0; fi; local exit_code=$?
#   Problem:  $? after an if-block is the exit status of the if construct (always 0),
#             NOT the exit status of the failed command inside the condition.
#   Fix:      Capture exit code with `"$@" || exit_code=$?` which runs the command
#             and captures its exit code in a single atomic operation.
retry_with_backoff() {
    local max_attempts="$1"
    local base_delay="$2"
    local max_delay="$3"
    shift 3

    local attempt=1
    local delay="$base_delay"

    while [[ $attempt -le $max_attempts ]]; do
        local exit_code=0
        "$@" || exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            return 0
        fi

        if [[ $attempt -eq $max_attempts ]]; then
            log_error "$PHASE_NAME" "failed after ${max_attempts} attempts (exit ${exit_code})"
            return $exit_code
        fi

        log_warn "$PHASE_NAME" "attempt ${attempt}/${max_attempts} failed, retrying in ${delay}s"
        sleep "$delay"

        # Exponential backoff with cap
        delay=$((delay * 2))
        if [[ $delay -gt $max_delay ]]; then
            delay=$max_delay
        fi
        attempt=$((attempt + 1))
    done
}

# ------------------------------- RATE LIMITER -------------------------------
# Token-bucket rate limiter (shell-native).
# Usage: rate_limit_init <requests_per_second>
#        rate_limit_wait
_rate_limit_rps=0
_rate_limit_last=0

rate_limit_init() {
    _rate_limit_rps="$1"
    _rate_limit_last=$(date +%s%N 2>/dev/null || date +%s)
}

rate_limit_wait() {
    [[ $_rate_limit_rps -eq 0 ]] && return 0
    local now
    now=$(date +%s%N 2>/dev/null || date +%s)
    local interval=$(( 1000000000 / _rate_limit_rps ))
    local elapsed=$(( now - _rate_limit_last ))
    if [[ $elapsed -lt $interval ]]; then
        local sleep_ns=$(( interval - elapsed ))
        local sleep_s=$(( sleep_ns / 1000000000 ))
        local sleep_rem=$(( (sleep_ns % 1000000000) / 1000000 ))
        sleep "${sleep_s}.${sleep_rem}"
    fi
    _rate_limit_last=$(date +%s%N 2>/dev/null || date +%s)
}

# ------------------------------- JSON SUMMARY --------------------------------
# Write phase summary as JSON. Builds JSON programmatically to prevent injection.
# Usage: phase_summary <phase_name> <metric_name> <count> [extra_json]
phase_summary() {
    local phase="$1"
    local metric="$2"
    local count="$3"
    local extra="${4:-}"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local summary_file="${RECON_DIR}/${phase}/summary.json"

    # Escape values for safe JSON embedding
    local safe_phase safe_metric
    safe_phase=$(_json_escape "$phase")
    safe_metric=$(_json_escape "$metric")

    if [[ -n "$extra" ]]; then
        # $extra is caller-controlled JSON fragments (e.g. "reason":"no_wordlist")
        # Still build the outer structure programmatically for the core fields.
        cat > "$summary_file" <<ENDJSON
{
  "phase": "${safe_phase}",
  "metric": "${safe_metric}",
  "count": ${count},
  "timestamp": "${ts}",
  ${extra}
}
ENDJSON
    else
        cat > "$summary_file" <<ENDJSON
{
  "phase": "${safe_phase}",
  "metric": "${safe_metric}",
  "count": ${count},
  "timestamp": "${ts}"
}
ENDJSON
    fi
    log_info "$phase" "summary: ${metric}=${count}"
}

# ------------------------------- INPUT VALIDATION ---------------------------
# Check that input file exists and is non-empty.
# Usage: require_input <file> <phase_name>
require_input() {
    local file="$1"
    local phase="$2"
    if [[ ! -s "$file" ]]; then
        log_warn "$phase" "SKIP: input file empty or missing: ${file}"
        phase_summary "$phase" "skipped" 0 "\"reason\":\"empty_input\""
        return 1
    fi
    return 0
}

# ------------------------------- CONFIG VALIDATION --------------------------
# Require a config key to have a non-empty value. Exits on missing config.
# Usage: require_config "tools.subfinder"
#        val=$(require_config "retry.max_attempts")
require_config() {
    local key="$1"
    local val
    val=$(yaml_get "$key")
    if [[ -z "$val" ]]; then
        log_error "${PHASE_NAME:-init}" "required config missing: ${key}"
        echo "ERROR: required config missing: ${key}" >&2
        exit 1
    fi
    echo "$val"
}

# ------------------------------- COUNT UTILITY ------------------------------
# Safe line count (returns 0 if file missing).
# Usage: safe_wc <file>
safe_wc() {
    wc -l < "$1" 2>/dev/null || echo 0
}

# ------------------------------- INIT PHASE ---------------------------------
# Common initialization for all phase scripts.
# Call at the top of each phase: phase_init "01_subdomains" "subdomains"
phase_init() {
    local phase_dir_name="$1"
    PHASE_NAME="$phase_dir_name"

    # Load config
    CONFIG_FILE="${CONFIG_FILE:-${PIPELINE_DIR}/config.yaml}"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "ERROR: config not found: ${CONFIG_FILE}" >&2
        exit 1
    fi

    RECON_DIR=$(yaml_get "global.output_dir" "./recon")
    RECON_DIR="${PIPELINE_DIR}/${RECON_DIR#./}"
    PHASE_DIR="${RECON_DIR}/${phase_dir_name}"
    mkdir -p "$PHASE_DIR"

    # Init logging
    _LOG_FILE=$(yaml_get "global.log_file" "${RECON_DIR}/08_reports/pipeline.log")
    mkdir -p "$(dirname "$_LOG_FILE")"

    # Init checkpoint
    checkpoint_init

    # Set tool paths as environment
    export SUBFINDER=$(yaml_get "tools.subfinder" "/go/bin/subfinder")
    export HTTPX=$(yaml_get "tools.httpx" "/go/bin/httpx")
    export KATANA=$(yaml_get "tools.katana" "/go/bin/katana")
    export GAU=$(yaml_get "tools.gau" "/go/bin/gau")
    export WAYBACKURLS=$(yaml_get "tools.waybackurls" "/go/bin/waybackurls")
    export FFUF=$(yaml_get "tools.ffuf" "/go/bin/ffuf")
    export ARJUN=$(yaml_get "tools.arjun" "arjun")
    export LINKFINDER="${PIPELINE_DIR}/$(yaml_get "tools.linkfinder" "./LinkFinder/linkfinder.py")"

    # Get retry config
    RETRY_MAX=$(yaml_get "retry.max_attempts" "3")
    RETRY_BASE=$(yaml_get "retry.base_delay" "2")
    RETRY_MAX_DELAY=$(yaml_get "retry.max_delay" "30")

    # Init rate limiter for this phase
    local tool_name="${phase_dir_name#*_}"
    local rps
    rps=$(yaml_get "rate_limit.${tool_name}" "0")
    rate_limit_init "$rps"
}

# ------------------------------- STANDARD ARG PARSING ------------------------
# Handles the common --target, --config, --resume flags used by all phases.
# Sets TARGET, CONFIG_FILE, RESUME as side effects.
# Usage: phase_parse_args "$@"  (call after phase_init)
# Requires: TARGET="" RESUME=0 to be declared before calling.
phase_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target)  TARGET="$2"; shift 2 ;;
            --config)  CONFIG_FILE="$2"; shift 2 ;;
            --resume)  RESUME=1; shift ;;
            *)         echo "Unknown arg: $1" >&2; exit 1 ;;
        esac
    done
    # Fall back to config if target not set on CLI
    if [[ -z "$TARGET" ]]; then
        TARGET=$(yaml_get "global.target" "")
    fi
}

# ------------------------------- RESUME CHECK --------------------------------
# Checks if this phase was already completed (resume mode).
# Usage: phase_check_resume  (returns 0 and exits if already done)
phase_check_resume() {
    if [[ "$RESUME" -eq 1 ]] && checkpoint_has "$PHASE_NAME"; then
        log_info "$PHASE_NAME" "already completed (resume mode), skipping"
        exit 0
    fi
}

# ------------------------------- ENABLED CHECK -------------------------------
# Checks if this phase is enabled in config.
# Usage: phase_check_enabled  (returns 1 and exits if disabled)
phase_check_enabled() {
    local key="phases.${PHASE_NAME#*_}.enabled"
    local default="${1:-1}"
    local enabled
    enabled=$(yaml_get "$key" "$default")
    if [[ "$enabled" -eq 0 ]]; then
        log_info "$PHASE_NAME" "disabled in config, skipping"
        exit 0
    fi
}

# ------------------------------- PHASE FINISH --------------------------------
# Writes summary JSON and sets checkpoint. Call at end of every phase.
# Usage: phase_finish <metric> <count> [extra_json]
phase_finish() {
    local metric="$1"
    local count="$2"
    local extra="${3:-}"
    phase_summary "$PHASE_NAME" "$metric" "$count" "$extra"
    checkpoint_set "$PHASE_NAME"
}
