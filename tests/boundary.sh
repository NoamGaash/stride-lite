#!/usr/bin/env bash
# The application code knows nothing of where it runs. Everything particular to
# one environment lives under deploy/<environment>/ and reaches the code as an
# environment variable, so a fork that sets its own values runs end to end.
set -euo pipefail
cd "$(dirname "$0")/.."
hits=$(git grep -nE 'systemctl|/opt/stride-lite|/etc/|NoamGaash|621816331709|d2uqtzxw09mygh|openbus-mot-archive' \
  -- api/src db ingest scripts up.sh ':!*.md' || true)
if [ -n "$hits" ]; then
  echo "FAIL: environment-specific values outside deploy/:" >&2
  echo "$hits" >&2
  exit 1
fi
echo "boundary: ok"
