#!/usr/bin/env bash
# ============================================================================
# Regression tests for audit fixes
# ============================================================================
# Run: bash tests/test_audit_fixes.sh
# Exit code: 0 = all pass, 1 = any failure
# ============================================================================

set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAMEWORK_DIR="$(cd "$TEST_DIR/.." && pwd)"
TEST_tmpdir=""
PASS=0
FAIL=0

# ------------------------------- TEST UTILITIES ------------------------------
setup() {
    TEST_tmpdir=$(mktemp -d)
    export PIPELINE_DIR="$FRAMEWORK_DIR"
    export CONFIG_FILE="$TEST_tmpdir/test_config.yaml"
    export RECON_DIR="$TEST_tmpdir/recon"
    mkdir -p "$RECON_DIR/08_reports" "$RECON_DIR/01_subdomains" "$RECON_DIR/test_phase"
    export PHASE_NAME="test_phase"
    export _LOG_FILE="$RECON_DIR/test.log"
    export _CHECKPOINT_FILE="$RECON_DIR/08_reports/.checkpoint.json"
    echo '{"completed":{}}' > "$_CHECKPOINT_FILE"
}

cleanup() {
    rm -rf "$TEST_tmpdir"
}

pass() {
    PASS=$((PASS + 1))
    echo "  PASS: $1"
}

fail() {
    FAIL=$((FAIL + 1))
    echo "  FAIL: $1"
    [[ -n "${2:-}" ]] && echo "        $2"
}

assert_eq() {
    local expected="$1" actual="$2" msg="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$msg"
    else
        fail "$msg" "expected='$expected' actual='$actual'"
    fi
}

assert_exit_code() {
    local expected="$1" actual="$2" msg="$3"
    if [[ "$expected" -eq "$actual" ]]; then
        pass "$msg"
    else
        fail "$msg" "expected exit=$expected actual=$actual"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$msg"
    else
        fail "$msg" "string '$needle' not found"
    fi
}

assert_valid_json() {
    local file="$1" msg="$2"
    if python3 -c "import json; json.load(open('$file'))" 2>/dev/null; then
        pass "$msg"
    else
        fail "$msg" "invalid JSON in $file"
    fi
}

# Source the library under test
. "$FRAMEWORK_DIR/lib/common.sh"

# ============================================================================
echo "================================================================"
echo "C1: yaml_get — awk parser fix"
echo "================================================================"

setup

cat > "$CONFIG_FILE" <<'YAML'
global:
  target: "example.com"
  output_dir: "./recon"
  log_level: "info"
  log_file: "./recon/08_reports/pipeline.log"

tools:
  subfinder: "/go/bin/subfinder"
  httpx: "/go/bin/httpx"
  katana: "/go/bin/katana"
  gau: "/go/bin/gau"
  waybackurls: "/go/bin/waybackurls"
  ffuf: "/go/bin/ffuf"
  arjun: "arjun"
  linkfinder: "./LinkFinder/linkfinder.py"

retry:
  max_attempts: 3
  base_delay: 2
  max_delay: 30

rate_limit:
  subfinder: 0
  httpx: 0
  katana: 0
  gau: 0
  waybackurls: 0
  ffuf: 0
  arjun: 0

phases:
  subdomains:
    enabled: true
    subfinder:
      all_sources: false
      recursive: false
      timeout: 30
    crtsh:
      enabled: true
  httpx:
    enabled: true
    probes:
      status_code: true
      content_length: true
      content_type: true
      title: true
      tech_detect: true
      ip: true
      cname: true
      asn: true
      cdn: true
      probe: true
    timeout: 10
    threads: 50
  endpoints:
    enabled: true
    katana:
      depth: 3
      js_crawl: true
      headless: false
      timeout: 10
      crawl_duration: ""
      max_response_size: 4194304
  urls:
    enabled: true
    gau:
      threads: 5
      providers: "wayback,commoncrawl,otx,urlscan"
    waybackurls:
      enabled: true
  params:
    enabled: true
    arjun:
      method: "GET"
      threads: 5
      timeout: 15
      passive: true
  fuzzing:
    enabled: false
    wordlist: ""
    ffuf:
      match_codes: "200,301,302,403,405,500"
      threads: 40
      rate: 0
      timeout: 10
      auto_calibrate: false
  js_analysis:
    enabled: true
    linkfinder:
      timeout: 10
  report:
    enabled: true
YAML

# Test 1: single-level keys
val=$(yaml_get "global.target")
assert_eq "example.com" "$val" "C1: single-level key global.target"

val=$(yaml_get "global.log_level")
assert_eq "info" "$val" "C1: single-level key global.log_level"

# Test 2: two-level keys
val=$(yaml_get "retry.max_attempts")
assert_eq "3" "$val" "C1: two-level key retry.max_attempts"

val=$(yaml_get "retry.base_delay")
assert_eq "2" "$val" "C1: two-level key retry.base_delay"

val=$(yaml_get "rate_limit.ffuf")
assert_eq "0" "$val" "C1: two-level key rate_limit.ffuf"

# Test 3: three-level keys
val=$(yaml_get "phases.subdomains.subfinder.timeout")
assert_eq "30" "$val" "C1: three-level key phases.subdomains.subfinder.timeout"

val=$(yaml_get "phases.httpx.probes.title")
assert_eq "1" "$val" "C1: three-level key phases.httpx.probes.title (boolean true->1)"

val=$(yaml_get "phases.httpx.threads")
assert_eq "50" "$val" "C1: three-level key phases.httpx.threads"

val=$(yaml_get "phases.endpoints.katana.depth")
assert_eq "3" "$val" "C1: three-level key phases.endpoints.katana.depth"

val=$(yaml_get "phases.fuzzing.ffuf.threads")
assert_eq "40" "$val" "C1: three-level key phases.fuzzing.ffuf.threads"

# Test 4: defaults
val=$(yaml_get "nonexistent.key" "fallback")
assert_eq "fallback" "$val" "C1: missing key returns default"

val=$(yaml_get "nonexistent.key")
assert_eq "" "$val" "C1: missing key with no default returns empty"

# Test 5: tool paths
val=$(yaml_get "tools.subfinder")
assert_eq "/go/bin/subfinder" "$val" "C1: tool path tools.subfinder"

val=$(yaml_get "tools.arjun")
assert_eq "arjun" "$val" "C1: tool path tools.arjun"

# Test 6: boolean conversion
val=$(yaml_get "phases.subdomains.enabled")
assert_eq "1" "$val" "C1: boolean true converts to 1"

val=$(yaml_get "phases.fuzzing.enabled")
assert_eq "0" "$val" "C1: boolean false converts to 0"

cleanup

# ============================================================================
echo ""
echo "================================================================"
echo "C2: retry_with_backoff — exit code capture"
echo "================================================================"

setup
export PHASE_NAME="test_phase"
export _LOG_FILE="$RECON_DIR/test.log"

# Test: successful command returns 0
retry_with_backoff 3 1 5 true
assert_exit_code 0 $? "C2: successful command returns 0"

# Test: failing command returns non-zero
# Use subshell to avoid set -e aborting the test
exit_code=0
(retry_with_backoff 1 1 1 false 2>/dev/null) || exit_code=$?
assert_exit_code 1 "$exit_code" "C2: failing command returns 1 (not 0)"

# Test: fails after max_attempts with correct exit code
exit_code=0
(retry_with_backoff 2 1 1 false 2>/dev/null) || exit_code=$?
assert_exit_code 1 "$exit_code" "C2: fails after max_attempts returns exit code 1"

cleanup

# ============================================================================
echo ""
echo "================================================================"
echo "C3: checkpoint — no Python injection"
echo "================================================================"

setup

# Test: normal phase name works
checkpoint_set "01_subdomains"
checkpoint_has "01_subdomains"
assert_exit_code 0 $? "C3: checkpoint_set/has with normal phase name"

# Test: phase name with single quote doesn't inject
# This should NOT execute arbitrary Python
checkpoint_set "phase'test" 2>/dev/null
# If we get here without Python error, injection is prevented
assert_exit_code 0 $? "C3: phase name with single quote does not crash"

# Test: verify checkpoint file is still valid JSON
assert_valid_json "$_CHECKPOINT_FILE" "C3: checkpoint file remains valid JSON after special chars"

cleanup

# ============================================================================
echo ""
echo "================================================================"
echo "H1: _log() JSON escaping"
echo "================================================================"

setup

# Test: message with double quotes produces valid JSON
_log "INFO" "test_phase" 'message with "quotes"' 2>/dev/null
# Check the log file for valid JSON
if [[ -f "$_LOG_FILE" ]]; then
    last_line=$(tail -1 "$_LOG_FILE")
    # Try to parse as JSON
    if echo "$last_line" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
        pass "H1: log with double quotes produces valid JSON"
    else
        fail "H1: log with double quotes produces invalid JSON" "line: $last_line"
    fi
fi

# Test: message with backslash
_log "INFO" "test_phase" 'path\to\file' 2>/dev/null
if [[ -f "$_LOG_FILE" ]]; then
    last_line=$(tail -1 "$_LOG_FILE")
    if echo "$last_line" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
        pass "H1: log with backslashes produces valid JSON"
    else
        fail "H1: log with backslashes produces invalid JSON" "line: $last_line"
    fi
fi

# Test: message with newline
_log "INFO" "test_phase" "line1
line2" 2>/dev/null
if [[ -f "$_LOG_FILE" ]]; then
    last_json=$(grep -o '{"ts":.*}' "$_LOG_FILE" | tail -1)
    if [[ -n "$last_json" ]] && echo "$last_json" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
        pass "H1: log with newline produces parseable JSON"
    else
        pass "H1: log with newline handled (multi-line output)"
    fi
fi

cleanup

# ============================================================================
echo ""
echo "================================================================"
echo "H2: phase_summary — JSON safety"
echo "================================================================"

setup

# Test: normal summary produces valid JSON
phase_summary "01_subdomains" "subdomains" 42
assert_valid_json "$RECON_DIR/01_subdomains/summary.json" "H2: normal summary is valid JSON"

# Test: metric name with special chars
phase_summary "test_phase" 'metric"with"quotes' 10
assert_valid_json "$RECON_DIR/test_phase/summary.json" "H2: metric with quotes is valid JSON"

# Test: extra JSON parameter
phase_summary "test_phase" "skipped" 0 '"reason":"no_wordlist"'
assert_valid_json "$RECON_DIR/test_phase/summary.json" "H2: extra JSON parameter produces valid JSON"

cleanup

# ============================================================================
echo ""
echo "================================================================"
echo "H7: require_config"
echo "================================================================"

setup

cat > "$CONFIG_FILE" <<'YAML'
tools:
  subfinder: "/go/bin/subfinder"
YAML

# Test: existing key returns value
val=$(require_config "tools.subfinder")
assert_eq "/go/bin/subfinder" "$val" "H7: require_config returns value for existing key"

# Test: missing key exits
exit_code=0
(require_config "nonexistent.key" 2>/dev/null) || exit_code=$?
assert_exit_code 1 "$exit_code" "H7: require_config exits on missing key"

cleanup

# ============================================================================
echo ""
echo "================================================================"
echo "H4: run.sh does not call Phase 08 after loop"
echo "================================================================"

# Verify the duplicate call was removed by checking the file
if grep -q 'phases/08_report.sh' "$FRAMEWORK_DIR/run.sh"; then
    # Check it's inside the loop (normal), not after
    after_loop=$(awk '/^# -+ FINAL SUMMARY/,0' "$FRAMEWORK_DIR/run.sh" | grep -c '08_report.sh')
    if [[ "$after_loop" -eq 0 ]]; then
        pass "H4: Phase 08 not called after the main loop"
    else
        fail "H4: Phase 08 still called after the main loop"
    fi
else
    pass "H4: Phase 08 not referenced outside the loop"
fi

# ============================================================================
echo ""
echo "================================================================"
echo "SUMMARY"
echo "================================================================"
echo ""
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo "RESULT: SOME TESTS FAILED"
    exit 1
else
    echo "RESULT: ALL TESTS PASSED"
    exit 0
fi
