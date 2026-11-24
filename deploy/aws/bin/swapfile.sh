#!/usr/bin/env bash
# A 2 GiB swap file, for the nights a backfill or a heavy view wants more than
# the RAM: slower then, instead of killed. Swappiness is low so that the API's
# working set stays in RAM by day. Run at boot by swapfile.service; idempotent.
set -euo pipefail
F=${SWAPFILE:-/swapfile}

sysctl -q vm.swappiness=10
swapon --show=NAME --noheadings | grep -qx "$F" && exit 0
if [ ! -f "$F" ]; then
  fallocate -l 2G "$F"
  chmod 600 "$F"
  mkswap "$F" >/dev/null
fi
swapon "$F"
