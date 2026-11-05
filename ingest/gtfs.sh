#!/usr/bin/env bash
# Load one day of the GTFS feed.
#
#   ./ingest/gtfs.sh 2026 11 03
#   ./ingest/gtfs.sh            # yesterday, which is the newest complete feed
#
# The archive is public and in the same region as everything else, so this
# needs no credentials. One day is a 149 MB zip holding a 596 MB stop_times.txt;
# both are removed when the load finishes.
#
# Safe to re-run: ingest/gtfs.sql skips a date whose rows are already there.
set -euo pipefail
cd "$(dirname "$0")/.."

CH_DB=${CH_DB:-stride}
CH=${CH_CLIENT:-clickhouse client}
if [ $# -ge 3 ]; then
  year=$1; month=$2; day=$3
else
  read -r year month day <<<"$(date -u -d yesterday +'%Y %m %d')"
fi
date_iso="$year-$month-$day"
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

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
