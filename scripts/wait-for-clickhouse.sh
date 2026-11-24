#!/usr/bin/env bash
# Waits until ClickHouse answers a query. After a restart it loads its tables
# first and refuses connections meanwhile, and deploy/aws/bin/deploy.sh restarts it
# (through install-node-config.sh) just before applying the schema: on
# 2026-11-23 that order failed a deploy with "Connection refused" while the
# server was a few seconds from ready.
set -euo pipefail
CH=${CH_CLIENT:-clickhouse client}
TRIES=${CH_WAIT_TRIES:-120}   # five seconds apart: ten minutes
for ((i = 1; i <= TRIES; i++)); do
  $CH --query 'SELECT 1' >/dev/null 2>&1 && exit 0
  sleep "${CH_WAIT_SECONDS:-5}"
done
echo "ClickHouse did not answer within $TRIES tries" >&2
exit 1
