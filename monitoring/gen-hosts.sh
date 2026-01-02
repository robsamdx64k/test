#!/usr/bin/env bash
# Generate hosts.txt quickly for sequential IPs.
# Usage: ./gen-hosts.sh 10.0.0 101 400 > hosts.txt
set -euo pipefail
PREFIX="${1:?prefix like 10.0.0}"
START="${2:?start like 101}"
END="${3:?end like 400}"
for i in $(seq "$START" "$END"); do
  echo "${PREFIX}.${i}"
done
