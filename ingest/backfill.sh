#!/usr/bin/env bash
# Loads a past range of SIRI snapshots. The continuous views in ingest/siri.sql
# only cover the last two hours; anything older comes through here.
#
#   ./ingest/backfill.sh 2026 11 01            # one day
#   ./ingest/backfill.sh 2026 11 01 14         # one hour
#
# Safe to re-run and safe to run while the continuous views are live: the same
# NOT IN filter applies, so an hour already loaded reads 60 file headers and
# writes nothing.
set -euo pipefail

CH_DB=${CH_DB:-stride}
CH=${CH_CLIENT:-clickhouse client}
year=${1:?usage: backfill.sh <year> <month> <day> [hour]}
month=${2:?}; day=${3:?}; hour=${4:-}
glob="$year/$month/$day/${hour:-*}"

echo "backfilling $glob"
sed "s|__GLOB__|$glob|" "$(dirname "$0")/backfill.sql" \
  | $CH --database "$CH_DB" --multiquery
$CH --database "$CH_DB" --query "
  SELECT count() AS snapshots_loaded
  FROM siri_snapshot_seen FINAL
  WHERE siri_snapshot_id LIKE '$year/$month/$day/%'"
