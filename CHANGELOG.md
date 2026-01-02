# Changelog

## v2-manager (2026-01-01)
- Added `manager.sh` + `manager.conf` (watchdog, thermal pause/resume, stale-hash restart, CPU pinning via taskset, screen support).
- Fixed/standardized ccminer API port default to 4068 in `monitoring/api.pl`.
- Replaced broken `monitoring/check-all` with robust version that reads `monitoring/hosts.txt`.
- Added `monitoring/gen-hosts.sh` and `monitoring/status.sh`.
