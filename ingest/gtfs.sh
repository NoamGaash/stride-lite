#!/usr/bin/env bash
# Load the GTFS feed for a day.
#
#   ./ingest/gtfs.sh 2026 11 03   # that day
#   ./ingest/gtfs.sh              # every day with SIRI and no GTFS, and today
#
# The question is not "what comes after the newest day" but "which days have
# rides and no schedule". The first load brought SIRI up to date from the
# archive and GTFS only for its last day, which left five months of rides with
# no GTFS behind a newest day that looked current; walking forward from it never
# looks back. So the days are read off siri_snapshot_seen instead.
#
# The archive publishes a day's feed at about 00:01 UTC that same day, so today
# is included even before its SIRI lands. A day the archive does not have is
# asked about with HEAD, which downloads nothing, and skipped; any other failure
# stops the run, so a gap is retried on the next run rather than left behind.
#
# MAX_DAYS bounds one run, because each day is a 149 MB download from Hasadna's
# bucket and minutes of CPU: a long gap heals over a few daily runs, or in one
# with MAX_DAYS raised by hand.
#
# The archive is public and in the same region as everything else, so this
# needs no credentials. One day is a 149 MB zip holding a 596 MB stop_times.txt;
# both are removed when the load finishes.
set -euo pipefail
self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.."

CH_DB=${CH_DB:-stride}
CH=${CH_CLIENT:-clickhouse client}
MAX_DAYS=${MAX_DAYS:-40}
ARCHIVE=https://openbus-stride-public.s3.eu-west-1.amazonaws.com/gtfs_archive

load_day() {
  local year=$1 month=$2 day=$3
  local date_iso="$year-$month-$day"
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  echo "== downloading $date_iso"
  curl -sS --fail -o "$workdir/feed.zip" \
    "$ARCHIVE/$year/$month/$day/israel-public-transportation.zip"

  echo "== extracting"
  # Only the six the loader reads; shapes.txt alone is another 228 MB.
  unzip -o -q "$workdir/feed.zip" \
    agency.txt calendar.txt routes.txt stops.txt trips.txt stop_times.txt -d "$workdir"

  echo "== staging"
  $CH --database "$CH_DB" --multiquery < ingest/gtfs-staging.sql
  for t in agency calendar routes stops trips stop_times; do
    $CH --database "$CH_DB" --query "TRUNCATE TABLE gtfs_raw_$t"
    # The feed's headers carry a UTF-8 BOM, so the column names are taken from
    # the table rather than from the file, and the header row is skipped.
    $CH --database "$CH_DB" \
        --query "INSERT INTO gtfs_raw_$t FORMAT CSV" \
        --input_format_csv_skip_first_lines=1 \
        --input_format_allow_errors_num=0 \
        < "$workdir/$t.txt"
    printf '   %-12s %s rows\n' "$t" "$($CH --database "$CH_DB" --query "SELECT count() FROM gtfs_raw_$t")"
  done

  echo "== deriving"
  $CH --database "$CH_DB" --param_date="$date_iso" --multiquery < ingest/gtfs.sql

  $CH --database "$CH_DB" --param_date="$date_iso" --query "
  SELECT
      (SELECT count() FROM gtfs_route WHERE date = {date:Date}) AS routes,
      (SELECT count() FROM gtfs_stop WHERE date = {date:Date}) AS stops,
      (SELECT count() FROM gtfs_ride WHERE gtfs_route_id IN
          (SELECT id FROM gtfs_route WHERE date = {date:Date})) AS rides,
      (SELECT count() FROM gtfs_ride_stop WHERE gtfs_ride_id IN
          (SELECT id FROM gtfs_ride WHERE gtfs_route_id IN
              (SELECT id FROM gtfs_route WHERE date = {date:Date}))) AS ride_stops
  FORMAT Vertical"
}

if [ $# -ge 3 ]; then
  load_day "$1" "$2" "$3"
  exit
fi

missing=$($CH --database "$CH_DB" --query "
  SELECT toString(d) FROM (
    SELECT DISTINCT toDate(replaceAll(substring(siri_snapshot_id, 1, 10), '/', '-')) AS d
    FROM siri_snapshot_seen
    UNION DISTINCT SELECT today())
  WHERE d NOT IN (SELECT DISTINCT assumeNotNull(date) FROM gtfs_route WHERE date IS NOT NULL)
  ORDER BY d DESC
  FORMAT TSV" </dev/null)
[ -n "$missing" ] || { echo "== up to date"; exit 0; }
echo "== $(echo "$missing" | wc -l) days with no GTFS, loading at most $MAX_DAYS"

loaded=0
for day in $missing; do
  [ "$loaded" -lt "$MAX_DAYS" ] || { echo "== reached MAX_DAYS=$MAX_DAYS, the rest is for the next run"; break; }
  path=$(date -u -d "$day" +%Y/%m/%d)
  if ! curl -sSfI -o /dev/null "$ARCHIVE/$path/israel-public-transportation.zip"; then
    echo "== $day is not in the archive, skipping"
    continue
  fi
  # A fresh shell and not a subshell: inside `|| ...` bash ignores set -e, and a
  # failed download would go on to truncate the staging tables and derive from
  # nothing.
  # shellcheck disable=SC2046
  "$self" $(date -u -d "$day" +'%Y %m %d') || { echo "== $day failed, stopping here" >&2; exit 1; }
  loaded=$((loaded + 1))
done
