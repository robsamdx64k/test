#!/usr/bin/env bash
# Prints miner status as JSON (for dashboards).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$HERE/manager.sh" status
