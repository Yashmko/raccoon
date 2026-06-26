# Raccoon

Modular reconnaissance framework for authorized security assessments.

## Legal Notice

**This toolset is for authorized security testing only.** Unauthorized access to computer systems is illegal. Always obtain written permission before conducting any security assessment.

## Architecture

```
.
├── config.yaml              # All settings (tools, phases, retry, rate-limit)
├── run.sh                   # Orchestrator — entry point
├── lib/
│   └── common.sh            # Shared: logging, retry, rate-limit, checkpoint, YAML
├── phases/
│   ├── 01_subdomains.sh     # subfinder + crt.sh
│   ├── 02_httpx.sh          # httpx (ProjectDiscovery)
│   ├── 03_endpoints.sh      # katana crawling
│   ├── 04_urls.sh           # gau + waybackurls
│   ├── 05_params.sh         # arjun parameter discovery
│   ├── 06_fuzzing.sh        # ffuf directory fuzzing
│   ├── 07_js_analysis.sh    # LinkFinder JS analysis
│   └── 08_report.sh         # Report generation
├── recon/                   # Output (gitignored)
└── LinkFinder/              # External tool
```

## Quick Start

```bash
# Run all enabled phases
./run.sh -t example.com

# Run specific phases
./run.sh -t example.com -p 1,2,4

# Resume from last checkpoint
./run.sh -t example.com --resume

# Use custom config
./run.sh -t example.com -c /path/to/config.yaml

# List phase status
./run.sh --list

# Reset checkpoints
./run.sh --reset
```

## Independent Execution

Every phase script runs standalone:

```bash
./phases/01_subdomains.sh --target example.com --config config.yaml
./phases/02_httpx.sh --target example.com --config config.yaml --resume
```

## Features

### Config-Driven

All settings in `config.yaml` — tool paths, phase toggles, rate limits, retry parameters, probe flags. No code changes needed.

### Structured Logging

JSON-formatted logs with timestamps, levels, and phase context:
```json
{"ts":"2026-06-26T19:30:00Z","level":"INFO","phase":"01_subdomains","msg":"subfinder: 42 subdomains"}
```

### Resume/Checkpoint

Each phase writes a checkpoint on completion. Re-running with `--resume` skips completed phases. Checkpoints stored in `recon/08_reports/.checkpoint.json`.

### Rate Limiting

Per-tool rate limits in `config.yaml`:
```yaml
rate_limit:
  subfinder: 0      # unlimited
  ffuf: 10          # 10 requests/second
```

### Retries with Exponential Backoff

Failed tool invocations retry automatically:
```yaml
retry:
  max_attempts: 3
  base_delay: 2     # seconds
  max_delay: 30     # seconds cap
```

### Phase Summaries

Each phase writes `summary.json` with structured metrics:
```json
{"phase": "01_subdomains", "metric": "subdomains", "count": 42, "timestamp": "..."}
```

### Dependency-Aware Orchestration

`run.sh` resolves phase dependencies automatically:
- Phase 01 (subdomains) → Phase 02 (httpx) → Phase 03 (endpoints)
- Phase 04 (urls) → Phase 05 (params)
- Phases 06, 07 run independently
- Phase 08 (report) runs last

## Configuration Reference

| Section | Purpose |
|---------|---------|
| `global` | Target domain, output dir, log level |
| `tools` | Path to each binary |
| `retry` | Max attempts, base/max delay |
| `rate_limit` | Per-tool requests/second |
| `phases.*` | Per-phase enable/disable and tool-specific flags |

See `config.yaml` for full documentation of all options.

## Tool Paths

| Tool | Path | Version |
|------|------|---------|
| subfinder | `/go/bin/subfinder` | v2.14.0 |
| httpx | `/go/bin/httpx` | v1.9.0 |
| katana | `/go/bin/katana` | v1.6.1 |
| gau | `/go/bin/gau` | 2.2.4 |
| waybackurls | `/go/bin/waybackurls` | — |
| ffuf | `/go/bin/ffuf` | 2.1.0-dev |
| arjun | `arjun` (pip3) | 2.2.7 |
| LinkFinder | `./LinkFinder/linkfinder.py` | — |

**Note:** `/go/bin/httpx` is ProjectDiscovery's httpx (Go). `which httpx` resolves to Python httpx — a different tool. The pipeline uses the correct binary via config.
