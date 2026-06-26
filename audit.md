# Senior Engineering Audit

**Auditor:** Staff Security Automation Engineer
**Date:** 2026-06-26
**Scope:** Full framework — `lib/common.sh`, `run.sh`, `phases/01-08`, `config.yaml`
**Severity Scale:** CRITICAL / HIGH / MEDIUM / LOW

---

## CRITICAL Findings

### C1: `yaml_get` is completely broken — returns empty for all values

**File:** `lib/common.sh:24-122`
**Impact:** Every config value returns empty string. All tool paths, timeouts, feature flags, and phase toggles silently fall back to defaults. The config file is effectively ignored.

**Root cause:** The awk parser modifies `$1` via `gsub(/:/, "", $1)`. In GNU awk, this reconstructs `$0` from fields using OFS (space). The original line `global:` becomes `global` in `$0`. The pattern `/^[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*:/` then fails because the colon is gone from `$0`.

**Evidence:**
```bash
$ cat > /tmp/test.yaml <<'EOF'
global:
  target: "example.com"
EOF
$ awk '
    /^[a-zA-Z_][a-zA-Z0-9_]*:/ {
        print "BEFORE: [" $0 "]"
        gsub(/:/, "", $1)
        print "AFTER:  [" $0 "]"
    }
' /tmp/test.yaml
BEFORE: [global:]
AFTER:  [global]           # <-- colon destroyed, regex won't match
```

**Fix:** Use `$0` directly via `sub()` instead of modifying `$1`:
```awk
# Wrong (destroys $0):
gsub(/:/, "", $1)

# Correct (preserves $0):
current_section = $0
sub(/:.*/, "", current_section)
```

---

### C2: `retry_with_backoff` always returns 0 — never detects tool failures

**File:** `lib/common.sh:209-239`
**Impact:** If subfinder, httpx, katana, or any tool crashes, the pipeline logs the failure but returns exit code 0. The orchestrator reports "completed" for failed phases. Downstream phases run against missing/corrupt data.

**Root cause:** `$?` is captured after the `if "$@"` construct, not from the failed command:
```bash
if "$@"; then       # <-- if block always succeeds (exit 0)
    return 0
fi
local exit_code=$?  # <-- $? is 0 (exit status of the if construct)
```

**Evidence:**
```bash
$ retry_with_backoff 3 1 5 false
$ echo $?            # prints 0, should be 1
```

**Fix:**
```bash
local exit_code=0
"$@" || exit_code=$?
if [[ $exit_code -eq 0 ]]; then
    return 0
fi
```

---

### C3: Command injection via phase name in Python code

**File:** `lib/common.sh:178-201`
**Impact:** `checkpoint_set` and `checkpoint_has` interpolate `$phase` directly into Python f-strings. A phase name containing `'` breaks the Python code. While current phase names are safe, custom phases or future modifications could inject arbitrary Python.

**Vulnerable code:**
```bash
checkpoint_set() {
    python3 -c "
data['completed']['${phase}'] = {'finished_at': '${ts}', 'status': 'ok'}
"  # if phase="foo'; import os; os.system('rm -rf /'); print('", Python executes it
}
```

**Fix:** Pass values as arguments, not string interpolation:
```bash
python3 -c "
import json, sys
phase, ts = sys.argv[1], sys.argv[2]
with open(sys.argv[3], 'r') as f:
    data = json.load(f)
data['completed'][phase] = {'finished_at': ts, 'status': 'ok'}
with open(sys.argv[3], 'w') as f:
    json.dump(data, f, indent=2)
" "$phase" "$ts" "$_CHECKPOINT_FILE"
```

---

## HIGH Findings

### H1: `_log()` performs JSON injection — malformed logs on special characters

**File:** `lib/common.sh:148`
**Impact:** If `$msg` contains `"` or `\`, the JSON log line is malformed. Tool output paths like `/path/to/file (1).json` or error messages with quotes break structured logging.

**Vulnerable code:**
```bash
local json="{\"ts\":\"${ts}\",\"level\":\"${level}\",\"phase\":\"${phase}\",\"msg\":\"${msg}\"}"
```

**Fix:** Escape JSON special characters:
```bash
msg=$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g')
phase=$(printf '%s' "$phase" | sed 's/\\/\\\\/g; s/"/\\"/g')
```

---

### H2: `phase_summary` has JSON injection via `$extra` parameter

**File:** `lib/common.sh:281-300`
**Impact:** The `$extra` parameter is interpolated raw into a JSON heredoc. Phase 06 and 07 pass `\"reason\":\"no_wordlist\"` — this works by accident. Any value with a `"` breaks the JSON.

**Vulnerable code:**
```bash
cat > "$summary_file" <<ENDJSON
{
  "phase": "${phase}",
  ${extra}
}
ENDJSON
```

**Fix:** Build JSON programmatically, not via heredoc interpolation.

---

### H3: No file locking on checkpoint file — concurrent corruption

**File:** `lib/common.sh:171-205`
**Impact:** Two pipeline instances against the same target corrupt `.checkpoint.json`. Even a single pipeline has a TOCTOU race between `checkpoint_has` (read) and `checkpoint_set` (write).

**Fix:** Use `flock` for atomic locking:
```bash
checkpoint_set() {
    (
        flock -w 5 200 || return 1
        python3 -c "..." "$phase" "$ts" "$_CHECKPOINT_FILE"
    ) 200>"${_CHECKPOINT_FILE}.lock"
}
```

---

### H4: `run.sh` runs Phase 08 twice

**File:** `run.sh:294-348`
**Impact:** Phase 08 (report) runs inside the phase loop (line 294-330) AND again after the loop (line 346-348). Generates duplicate reports, wastes time, and produces confusing output.

**Fix:** Remove the post-loop Phase 08 invocation, or exclude it from the loop.

---

### H5: Tool failure is silently swallowed — no abort on missing tools

**File:** `run.sh:319`
**Impact:** If Phase 01 (subfinder) fails, `retry_with_backoff` returns 0 (due to C2), and the pipeline continues to Phase 02 which probes an empty subdomain list. This cascades through all dependent phases producing empty results with "completed" status.

**Fix:** After C2 is fixed, add dependency checking: Phase 02 should verify Phase 01 produced non-empty output before running (already done via `require_input`, but the orchestrator should also check).

---

### H6: `linkfinder.py` errors are suppressed with `|| true`

**File:** `phases/07_js_analysis.sh:39-44`
**Impact:** LinkFinder failures (network errors, missing dependencies, bad input) are completely hidden. The phase reports success with 0 endpoints. The `retry_with_backoff` wrapper retries, but `|| true` masks the final failure.

**Fix:** Remove `|| true`. Let `retry_with_backoff` handle retries and failure reporting.

---

### H7: No validation of required config values

**File:** `lib/common.sh:328-371`
**Impact:** If a required config key is missing, `yaml_get` returns empty string. Tool paths become empty, timeouts become empty strings passed to tools. Tools receive invalid arguments and fail with cryptic errors.

**Fix:** Add `require_config` function:
```bash
require_config() {
    local key="$1"
    local val
    val=$(yaml_get "$key")
    if [[ -z "$val" ]]; then
        log_error "$PHASE_NAME" "required config missing: ${key}"
        exit 1
    fi
    echo "$val"
}
```

---

## MEDIUM Findings

### M1: `yaml_get` spawns a new awk process on every call

**File:** `lib/common.sh:24-122`
**Impact:** Each `yaml_get` call spawns awk parsing the entire config file. A single phase can call `yaml_get` 10-15 times. The full pipeline spawns 80-120 awk processes just for config reads.

**Quantified:** ~100 awk spawns × ~10ms each ≈ 1 second of pure overhead per pipeline run.

**Fix:** Parse config once into a bash associative array at startup:
```bash
declare -A CONFIG_CACHE
config_load() {
    while IFS='=' read -r key val; do
        CONFIG_CACHE["$key"]="$val"
    done < <(awk '...' "$CONFIG_FILE")
}
```

---

### M2: `checkpoint_set`/`checkpoint_has` spawn Python on every call

**File:** `lib/common.sh:178-201`
**Impact:** 8 phases × 2 calls each = 16 Python process spawns. Each Python startup is ~50ms. Total: ~800ms overhead.

**Fix:** Use `jq` (if available) or bash-native JSON manipulation for simple key-value updates.

---

### M3: Rate limiter uses `date +%s%N` — two processes per wait call

**File:** `lib/common.sh:253-267`
**Impact:** Each `rate_limit_wait` spawns two `date` processes (with fallback). With RPS > 0, this adds latency.

**Fix:** Use `$SECONDS` or bash's built-in time tracking.

---

### M4: No per-phase timeout — tools can hang indefinitely

**File:** All phase scripts
**Impact:** If katana or httpx hangs on a target, the entire pipeline blocks forever. No timeout wraps the phase execution.

**Fix:** Use `timeout` command in `run.sh`:
```bash
timeout "${PHASE_TIMEOUT:-3600}" bash "$phase_script" "${PHASE_ARGS[@]}"
```

---

### M5: `${RECON_DIR}/01_subdomains/subdomains.txt` is hardcoded in dependent phases

**File:** `phases/02_httpx.sh:23`, `phases/03_endpoints.sh:23`, `phases/05_params.sh:23`
**Impact:** Output directory naming is coupled across phases. If a directory is renamed, dependent phases break silently.

**Fix:** Each phase should write its primary output path to a well-known location (e.g., `${RECON_DIR}/.phase_outputs.json`) that downstream phases read.

---

### M6: `SKIPPED` counter declared but never incremented

**File:** `run.sh:291`
**Impact:** Minor — dead code. The `SKIPPED` variable is initialized but never used.

---

### M7: `_LOG_FILE` set in orchestrator is overwritten by `phase_init`

**File:** `run.sh:206-208` vs `lib/common.sh:345`
**Impact:** The orchestrator exports `_LOG_FILE`, but each phase script re-sources `common.sh` and overwrites `_LOG_FILE` via `phase_init`. The export is useless.

---

### M8: `log/plain` function name contains `/` — non-standard

**File:** `lib/common.sh:158`
**Impact:** Function names with `/` work in bash but are unusual and can confuse linters, editors, and other shell implementations.

**Fix:** Rename to `log_plain` or `logplain`.

---

## LOW Findings

### L1: `declare -A` requires Bash 4+

**File:** `run.sh:26`
**Impact:** macOS ships Bash 3.2. The orchestrator fails on macOS without Homebrew Bash.

**Mitigation:** Shebang is `#!/usr/bin/env bash`. Document Bash 4+ requirement.

---

### L2: `log/plain` uses `$*` — word splitting risk

**File:** `lib/common.sh:161`
**Impact:** Arguments with spaces are concatenated without explicit quoting. In practice, messages are always single strings, but it's technically incorrect.

**Fix:** Use `"$*"` (quoted).

---

### L3: `parse_phase_list` uses `read -ra` with mutable `IFS`

**File:** `run.sh:96`
**Impact:** `IFS=','` is set for the `read` command but could affect subsequent operations if not restored.

**Fix:** Use `IFS=',' read -ra items <<< "$input"` (current code does this correctly with inline IFS, but restore IFS after).

---

### L4: `LINKFINDER` path double-concatenates `PIPELINE_DIR`

**File:** `lib/common.sh:359`
**Impact:** `LINKFINDER="${PIPELINE_DIR}/$(yaml_get "tools.linkfinder" "./LinkFinder/linkfinder.py")"`. If the config value is an absolute path, this creates a broken path like `/workspace/./LinkFinder/linkfinder.py`. Works by accident because `./` resolves correctly.

---

### L5: `phase_init` calls `mkdir -p` on every invocation

**File:** `lib/common.sh:342`
**Impact:** Each phase creates its output directory even if it's about to be skipped (disabled or already completed).

---

### L6: Hardcoded `python3` dependency

**File:** Multiple locations
**Impact:** Python 3 is required for JSON manipulation, crt.sh parsing, and LinkFinder. No fallback.

---

### L7: `exit $FAILED` at end of `run.sh` — non-zero exit on any failure

**File:** `run.sh:350`
**Impact:** If any phase fails, the orchestrator exits non-zero. This is correct behavior, but callers (CI/CD) may not expect non-zero on partial success.

---

## Duplicate Logic Summary

| Pattern | Locations | Issue |
|---------|-----------|-------|
| Tool path exports | `run.sh:229-250`, `common.sh:351-359` | Orchestrator checks tools but exports don't propagate to child phases |
| `mkdir -p` for output dirs | `run.sh:204`, `common.sh:342` | Both create the same directories |
| `_LOG_FILE` initialization | `run.sh:206-208`, `common.sh:345` | Orchestrator sets it, phase_init overwrites it |
| TARGET validation | `01_subdomains.sh:18`, `04_urls.sh:18`, `07_js_analysis.sh:18` | Each phase independently checks `[[ -z "$TARGET" ]]` |

---

## Performance Summary

| Bottleneck | Per-Call Cost | Total Calls | Total Cost |
|------------|--------------|-------------|------------|
| `yaml_get` (awk spawn) | ~10ms | ~100 | ~1s |
| `checkpoint_set` (python3 spawn) | ~50ms | 8 | ~400ms |
| `checkpoint_has` (python3 spawn) | ~50ms | 8 | ~400ms |
| `date +%s%N` (rate limiter) | ~5ms | ~20 | ~100ms |
| `date -u +"%Y-..."` (logging) | ~5ms | ~100 | ~500ms |
| **Total overhead** | | | **~2.4s** |

Not catastrophic, but avoidable. For a pipeline that might run for minutes/hours, 2.4s of pure overhead is acceptable. But the architectural pattern of spawning a process per config read scales poorly.

---

## Recommendations Priority

1. **Fix C1 (yaml_get)** — Framework is non-functional without this
2. **Fix C2 (retry exit code)** — Failure detection is completely broken
3. **Fix C3 (Python injection)** — Security vulnerability
4. **Fix H1 (JSON logging injection)** — Corrupts audit trail
5. **Fix H4 (double Phase 08)** — Wasted work
6. **Fix H7 (config validation)** — Silent failures
7. **Fix M1 (yaml_get caching)** — Performance
8. **Fix M4 (per-phase timeout)** — Reliability
