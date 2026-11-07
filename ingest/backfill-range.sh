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
#
# The landing rows are then KEPT. They are the only local copy of what was
# downloaded, and enrich-once.sql reads nothing but them, so keeping them is
# what makes a repair local instead of a second download out of Hasadna's
# bucket. DROP_LANDING=1 asks for the old behaviour; drop_month says why not to.
#
# ENRICH=0 loads the landing table and stops there, which is what
# ingest/catchup.sh wants: the live chain in ingest/enrich.sql reads the landing
# table whole every minute and will pick the rows up itself. Enriching here is
# for a cold load with that chain stopped — the two must not run at once, since
# the chain assigns ids as max(id) + row_number() and two concurrent passes hand
# out the same ones.
#
# So with ENRICH=1 this script stops the chain itself rather than asking the
# operator to remember. It used to only warn, in this comment, and that was not
# enough: a run with the chain left on corrupted every day from 2026-07-26 on,
# duplicating up to 5.6M rows a day and — because both passes started from the
# same max(id) — handing one id to two different readings, which makes `id` not
# a key. ingest/verify.sql is the gate that catches it; this is what prevents it.
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
# partial and worth asking S3 about again. Measured against 2026-08-19, which
# holds 455, and 2026-08-20, which holds 1,318: both are genuinely short.
MIN_SNAPSHOTS=${MIN_SNAPSHOTS:-1400}
ENRICH=${ENRICH:-1}
# Off by default: see drop_month for why keeping them is worth the disk.
DROP_LANDING=${DROP_LANDING:-0}

ch() { $CH --database "$CH_DB" "$@"; }

# shellcheck source=ingest/chain-guard.sh
. "$here/chain-guard.sh"

# The landing rows for a month are the only local copy of what was downloaded,
# and enrich-once.sql reads nothing else — so while they are here, re-enriching
# a day costs nothing and reaches no network. Dropping them turns any later
# mistake into a second download from somebody else's bucket.
#
# That trade is not close. A month of landing rows is about 2.8 GiB, so the whole
# archive is tens of GiB; re-fetching a month is thousands of files out of a
# non-profit's S3, billed to them and not to us. So this does nothing unless
# asked, and refuses when asked about a month it cannot verify: discarding the
# local copy of data already known to be damaged is how a cheap repair becomes
# an expensive one.
drop_month() {
  local part=$1
  [ "$DROP_LANDING" = 1 ] || return 0
  [ "$part" = "$(date -u +'%Y/%m')" ] && return 0
  local n
  n=$(ch --query "SELECT count() FROM system.parts WHERE database='$CH_DB' AND table='siri_vehicle_location_raw' AND partition='$part' AND active")
  [ "$n" = 0 ] && return 0

  local first last
  first="${part//\//-}-01"
  last=$(date -u -d "$first + 1 month - 1 day" +%F)
  if ! ch --param_from="$first" --param_to="$last" --queries-file "$here/verify.sql" >/dev/null 2>&1; then
    echo "  NOT dropping landing rows for $part: it does not verify, and they are the only local copy" >&2
    return 0
  fi

  echo "  dropping landing rows for $part"
  ch --query "ALTER TABLE siri_vehicle_location_raw DROP PARTITION '$part'"
}

# Is this day finished? The snapshot count alone was the old answer and it was
# the wrong question when this script enriches: siri_snapshot_seen says raw rows
# landed, not that anything was derived from them and not that what was derived
# is sound. A day that landed in full and then took duplicate ids from an
# overlapping pass passed that check, which is how twenty-nine damaged days
# survived a resume.
#
# So with ENRICH=1 the answer is the day's own health row, written by
# enrich-day.sql at the end of the day's pass: enough snapshots, locations
# derived from them, and no duplicate ids. FINAL because ingest_day_health is a
# ReplacingMergeTree keyed on the day, and a repair writes a second verdict that
# must outrank the first.
#
# With ENRICH=0 — catchup.sh, which lands rows and leaves them for the live
# chain — there is no health row to read and landing is the whole job, so the
# snapshot count is the right question after all.
day_is_done() {
  local landed
  landed=$(ch --query "
    SELECT count() FROM siri_snapshot_seen FINAL
    WHERE siri_snapshot_id LIKE '$(date -u -d "$1" +'%Y/%m/%d')/%'")
  [ "$landed" -ge "$MIN_SNAPSHOTS" ] || return 1
  [ "$ENRICH" = 1 ] || return 0
  [ "$(ch --query "
    SELECT count() FROM ingest_day_health FINAL
    WHERE day = toDate('$1')
      AND snapshots >= $MIN_SNAPSHOTS
      AND vehicle_locations > 0
      AND duplicate_ids = 0")" = 1 ]
}

if [ "$ENRICH" = 1 ]; then
  trap chain_restart EXIT INT TERM
  chain_stop
fi

day=$from
month=$(date -u -d "$from" +'%Y/%m')
end=$(date -u -d "$to" +%s)

while [ "$(date -u -d "$day" +%s)" -le "$end" ]; do
  this_month=$(date -u -d "$day" +'%Y/%m')
  if [ "$this_month" != "$month" ]; then
    drop_month "$month"
    month=$this_month
  fi

  if day_is_done "$day"; then
    echo "$day: already loaded, enriched and sound, skipping"
  else
    echo "$day: $(ch --query "
      SELECT count() FROM siri_snapshot_seen FINAL
      WHERE siri_snapshot_id LIKE '$(date -u -d "$day" +'%Y/%m/%d')/%'") snapshots loaded, fetching"
    # shellcheck disable=SC2086
    CH_DB="$CH_DB" CH_CLIENT="$CH" "$here/backfill.sh" $(date -u -d "$day" +'%Y %m %d')
    if [ "$ENRICH" = 1 ]; then
      ch --multiquery < "$here/enrich-once.sql"
      ch --multiquery --param_day="$day" < "$here/enrich-day.sql"
      # Checked here and not at the end of the range: the failure this guards
      # against duplicates a day at a time, and finding out after three weeks
      # of fetching means re-fetching three weeks.
      ch --param_from="$day" --param_to="$day" --queries-file "$here/verify.sql" >/dev/null
    fi
  fi

  day=$(date -u -d "$day + 1 day" +%F)
done

drop_month "$month"

if [ "$ENRICH" = 1 ]; then
  ch --query "
    SELECT
        min(recorded_at_time) AS earliest,
        max(recorded_at_time) AS latest,
        count() AS rows
    FROM siri_vehicle_location"
else
  ch --query "
    SELECT max(siri_snapshot_id) AS newest_snapshot_loaded
    FROM siri_snapshot_seen FINAL"
fi
