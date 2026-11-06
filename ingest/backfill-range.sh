#!/usr/bin/env bash
# Loads every SIRI snapshot between two dates, so the database holds the whole
# archive rather than whatever the dump happened to contain.
#
#   ./ingest/backfill-range.sh 2026-05-30 2026-11-02
#
# Oldest first, for the reason up.sh gives: a ride's scheduled_start_time is an
# argMin over its earliest observation, so loading forwards reaches the rows the
# live loop would have written.
#
# Enriches after each day instead of once at the end, because the enrichment's
# dedup reads the landing table whole and the landing table is what grows.
# A month's rows are dropped once that month is enriched, which the monthly
# PARTITION BY in db/raw.sql makes instant; the month still being ingested live
# is left alone. `siri_snapshot_seen` survives the drop, so nothing is re-read.
#
# Resumable: a day that already has its snapshots is skipped on the count rather
# than re-read, because confirming a day otherwise costs 1,440 file headers.
set -euo pipefail

CH_DB=${CH_DB:-stride}
CH=${CH_CLIENT:-clickhouse client}
here="$(cd "$(dirname "$0")" && pwd)"

from=${1:?usage: backfill-range.sh <from YYYY-MM-DD> <to YYYY-MM-DD>}
to=${2:?}

# A healthy requester writes about 1,430 snapshots a day. Below this a day is
# partial and worth asking S3 about again.
MIN_SNAPSHOTS=${MIN_SNAPSHOTS:-1400}

ch() { $CH --database "$CH_DB" "$@"; }

drop_month() {
  local part=$1
  [ "$part" = "$(date -u +'%Y/%m')" ] && return 0
  local n
  n=$(ch --query "SELECT count() FROM system.parts WHERE database='$CH_DB' AND table='siri_vehicle_location_raw' AND partition='$part' AND active")
  [ "$n" = 0 ] && return 0
  echo "  dropping landing rows for $part"
  ch --query "ALTER TABLE siri_vehicle_location_raw DROP PARTITION '$part'"
}

day=$from
month=$(date -u -d "$from" +'%Y/%m')
end=$(date -u -d "$to" +%s)

while [ "$(date -u -d "$day" +%s)" -le "$end" ]; do
  this_month=$(date -u -d "$day" +'%Y/%m')
  if [ "$this_month" != "$month" ]; then
    drop_month "$month"
    month=$this_month
  fi

  have=$(ch --query "
    SELECT count() FROM siri_snapshot_seen FINAL
    WHERE siri_snapshot_id LIKE '$(date -u -d "$day" +'%Y/%m/%d')/%'")

  if [ "$have" -ge "$MIN_SNAPSHOTS" ]; then
    echo "$day: $have snapshots already loaded, skipping"
  else
    echo "$day: $have snapshots loaded, fetching"
    # shellcheck disable=SC2086
    CH_DB="$CH_DB" CH_CLIENT="$CH" "$here/backfill.sh" $(date -u -d "$day" +'%Y %m %d')
    ch --multiquery < "$here/enrich-once.sql"
  fi

  day=$(date -u -d "$day + 1 day" +%F)
done

drop_month "$month"

ch --query "
  SELECT
      min(recorded_at_time) AS earliest,
      max(recorded_at_time) AS latest,
      count() AS rows
  FROM siri_vehicle_location"
