#!/usr/bin/env bash
# Load the GTFS feed for a day.
#
#   ./ingest/gtfs.sh 2026 11 03   # that day
#   ./ingest/gtfs.sh              # whichever of the last three days is missing
#
# The archive publishes a day's feed at about 00:01 UTC that same day, so a
# morning run can load today, as production serves it. Three days rather than
# one so a failed or skipped run heals on the next, and the check comes before
# the download, because every byte fetched is billed to Hasadna's bucket.
#
# The archive is public and in the same region as everything else, so this
# needs no credentials. One day is a 149 MB zip holding a 596 MB stop_times.txt;
# both are removed when the load finishes.
set -euo pipefail
self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.."

CH_DB=${CH_DB:-stride}
CH=${CH_CLIENT:-clickhouse client}

load_day() {
  local year=$1 month=$2 day=$3
  local date_iso="$year-$month-$day"
  local workdir
  workdir=$(mktemp -d)
  trap 'rm -rf "$workdir"' RETURN

  echo "== downloading $date_iso"
  curl -sS --fail -o "$workdir/feed.zip" \
    "https://openbus-stride-public.s3.eu-west-1.amazonaws.com/gtfs_archive/$year/$month/$day/israel-public-transportation.zip"

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

failed=0
for ago in 2 1 0; do
  date_iso=$(date -u -d "$ago days ago" +%F)
  loaded=$($CH --database "$CH_DB" --query "SELECT count() FROM gtfs_route WHERE date = '$date_iso'" </dev/null)
  if [ "$loaded" != 0 ]; then
    echo "== $date_iso already loaded"
    continue
  fi
  # A fresh shell and not a subshell: inside `|| ...` bash ignores set -e, and a
  # failed download would go on to truncate the staging tables and derive from
  # nothing.
  # shellcheck disable=SC2046
  "$self" $(date -u -d "$date_iso" +'%Y %m %d') || { echo "== $date_iso failed" >&2; failed=1; }
done
exit "$failed"
