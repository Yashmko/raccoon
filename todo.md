# Recon Pipeline TODO

## Completed

- [x] Modular framework architecture
- [x] config.yaml with all settings
- [x] lib/common.sh shared utilities (logging, retry, rate-limit, checkpoint, YAML parser)
- [x] 8 independent phase scripts
- [x] Orchestrator with dependency resolution
- [x] Resume/checkpoint capability
- [x] Rate limiting per tool
- [x] Exponential backoff retries
- [x] JSON phase summaries
- [x] Duplicated logic eliminated (arg parsing, checkpoint, enabled check in common.sh)
- [x] All scripts pass `bash -n` syntax validation

## Bugs Fixed (from v1)

- [x] arjun broken pipx symlink → global pip3 install
- [x] httpx binary conflict → hardcoded Go binary path
- [x] LinkFinder `-o` flag collision → stdout piping
- [x] Double tool invocations → single run
- [x] `set -e` aborting pipeline → per-phase error handling
- [x] Misleading `02_ports/` name → `02_live_hosts/`

## Remaining Work

### Before First Scan
- [ ] Download SecLists wordlists
- [ ] Test pipeline against non-sensitive domain
- [ ] Verify all tool paths in config.yaml

### Future Enhancements
- [ ] Add nuclei integration (Phase 09: vulnerability scanning)
- [ ] Add nmap/masscan to Phase 02
- [ ] Add subdomain takeover checks
- [ ] Add proxy support (Burp/ZAP)
- [ ] Add multi-target batch mode (`-dL` file of domains)
- [ ] Add webhook/email notification on completion
