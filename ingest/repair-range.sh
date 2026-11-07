#!/usr/bin/env bash
# Re-derives a date range from the landing table, so a day we damaged becomes a
# day we can stand behind.
#
#   ./ingest/repair-range.sh 2026-08-01 2026-08-23
#
# This is the local-only path, and that is a structural property and not a
# promise: the only S3 reader in the ingest is the `s3(...)` call in
# ingest/siri.sql and ingest/backfill.sql, and this script runs neither. It
# reads siri_vehicle_location_raw, deletes what was derived from it, and derives
# it again. A full day out of stride-siri-requester is 1,428 objects and 217 MiB
# — $0.022 of Hasadna's egress, measured off the bucket listing. This is $0.00,
# which is the entire reason ingest/backfill-range.sh now keeps the landing rows.
#
# It refuses a range whose landing rows are gone rather than deleting rows it
# cannot rebuild: see the second guard in repair.sql. If it refuses, the fix is
# backfill-range.sh over those days first, and that one does cost money.
#
# Oldest day first, like a backfill, and for the same reason: a ride's
# scheduled_start_time is an argMin over the snapshots in the batch, so a ride
# first mentioned on the 2nd must not be derived from the 3rd.
set -euo pipefail

CH_DB=${CH_DB:-stride}
CH=${CH_CLIENT:-clickhouse client}
here="$(cd "$(dirname "$0")" && pwd)"

from=${1:?usage: repair-range.sh <from YYYY-MM-DD> <to YYYY-MM-DD>}
to=${2:?}

ch() { $CH --database "$CH_DB" "$@"; }

# shellcheck source=ingest/chain-guard.sh
. "$here/chain-guard.sh"

# The no-network property, checked rather than asserted. Every S3 read in the
# ingest is an `s3(...)` table function, and the files below are everything this
# script hands to the server — so if a future edit puts a fetch into one of
# them, this stops before a byte of Hasadna's egress is spent rather than after.
for f in repair.sql enrich-once.sql verify.sql; do
  if grep -qiE '\bs3(Cluster)?[[:space:]]*\(' "$here/$f"; then
    echo "$f reads S3: this script is the local-only path and will not run it" >&2
    exit 1
  fi
done

# Not optional, and not a warning either. A repair is an enrichment pass, so a
# repair running beside the chain would mint the same ids twice — which is the
# damage being repaired. enrich-once.sql and repair.sql each refuse to start
# while the chain is enabled; this is what makes them able to start at all.
trap chain_restart EXIT INT TERM
chain_stop

echo "== deleting what was derived from $from .. $to"
ch --multiquery --param_from="$from" --param_to="$to" < "$here/repair.sql"

# The floors verify.sql audits against. Taken after the deletes and before the
# re-derivation, so the audit covers every id this pass could mint and every
# damaged id the deletes chose to leave behind — a duplicated id whose two rows
# straddle the range is not repairable from inside it, and the point of a floor
# rather than a watermark is that the final report still shows it.
ride_floor=$(ch --query "SELECT ifNull(min(id), 0) FROM repair_ride_seen")
ride_stop_floor=$(ch --query "
  SELECT ifNull(min(id), 0) FROM siri_ride_stop
  WHERE siri_ride_id IN (SELECT id FROM repair_ride_seen)")
echo "   auditing siri_ride from id $ride_floor, siri_ride_stop from id $ride_stop_floor"

# Three phases, and the split is not cosmetic.
#
# Deriving and verifying cannot be interleaved per day, because a day's rows do
# not come only from its own snapshots: a reading can be 22.7 hours older than
# the snapshot that carried it, so the duplicates dated 2026-08-19 were all
# minted from 2026-08-18's snapshots. Checking a day before its neighbours have
# been derived fails on damage that is about to be repaired, and the first
# version of this script aborted a sound run that way.
#
# So: derive everything, then judge everything, then record the judgement.

# Phase 1 — derive, oldest day first, because scheduled_start_time is an argMin
# over the snapshots in the batch. The marks are what keeps it one day at a
# time: siri_feed offers back every snapshot whose mark is gone and has no date
# filter of its own, so clearing the whole range at once would ask a single
# query to re-derive 133 million landing rows.
day=$from
end=$(date -u -d "$to" +%s)
while [ "$(date -u -d "$day" +%s)" -le "$end" ]; do
  echo "== deriving $day"
  ch --query "
    DELETE FROM siri_snapshot_enriched
    WHERE siri_snapshot_id IN (
        SELECT id FROM siri_snapshot
        WHERE snapshot_id LIKE '$(date -u -d "$day" +'%Y/%m/%d')/%')"
  ch --multiquery --param_day="$day" < "$here/enrich-once.sql"
  day=$(date -u -d "$day + 1 day" +%F)
done

# Phase 2 — judge. Per day and not per range: the day report holds a uniqExact
# state per group, and over 23 days that is 190 million ids at once, which
# exhausted the 8 GiB server and took the first run of this script down with it.
#
# Every day is checked before anything is reported, so one bad day does not hide
# the verdict on the other twenty-two. The exit code still carries the failure.
failed=""
day=$from
while [ "$(date -u -d "$day" +%s)" -le "$end" ]; do
  echo "== checking $day"
  if ! ch --param_from="$day" --param_to="$day" \
          --param_ride_from_id="$ride_floor" --param_ride_stop_from_id="$ride_stop_floor" \
          --queries-file "$here/verify.sql"; then
    failed="$failed $day"
  fi
  day=$(date -u -d "$day + 1 day" +%F)
done

# Phase 3 — record it where the API serves it. enrich-once.sql already wrote a
# health row for each day as it was derived, and every one of those is stale:
# they were measured before the later days of the range existed, and a later
# day's snapshots carry rows dated into the earlier ones. Re-measuring now is
# what stops /coverage reporting the damage as current —
# ReplacingMergeTree(measured_at) keyed on `day`, so the newest verdict wins and
# the endpoint reads it with FINAL.
day=$from
while [ "$(date -u -d "$day" +%s)" -le "$end" ]; do
  ch --query "INSERT INTO ingest_day_health SELECT * FROM ingest_day_health_src(day = toDate('$day'))"
  day=$(date -u -d "$day + 1 day" +%F)
done

echo "== the range, as the API now reports it"
ch --query "
  SELECT day, snapshots, vehicle_locations, duplicate_ids, duplicate_readings, rides
  FROM ingest_day_health FINAL
  WHERE day >= toDate('$from') AND day <= toDate('$to')
  ORDER BY day"

for t in repair_snapshot repair_ride_seen repair_ride_broken repair_ride_stop_broken; do
  ch --query "DROP TABLE IF EXISTS $t SYNC"
done

if [ -n "$failed" ]; then
  echo "still not sound:$failed" >&2
  exit 1
fi
