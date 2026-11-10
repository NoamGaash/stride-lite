#!/usr/bin/env bash
# A small, real database for tests/api/*.hurl: the 08:00 UTC hour of Pi Day 2025
# (a Friday, and Purim) and that day's GTFS, cut down to a few operators so it
# can live in the repository.
#
#   tests/api/fixture.sh load    # CI: schema + fixture, reads nothing remote
#   tests/api/fixture.sh build   # once, by hand: fetch the day, then cut
#   tests/api/fixture.sh cut     # re-cut from an already-built CH_DB
#
# `build` downloads a 149 MB GTFS zip and 60 SIRI files from Hasadna's bucket,
# billed to them, which is why its output is committed and CI only loads.
#
# Neither applies the REFRESH views in ingest/: they poll S3 every minute, and a
# test database has no business doing that. Only their tables and plain views.
set -euo pipefail
cd "$(dirname "$0")/../.."

CH_DB=${CH_DB:-stride_test}
CH=${CH_CLIENT:-clickhouse client}
DIR=tests/api/fixture
DAY=2025-03-14
HOUR=08
# Tnufa, and three small Jerusalem operators whose names put a hyphen where
# Hebrew collation has to decide what it means.
OPERATORS=34,49,50,51

ch() { $CH --database "$CH_DB" "$@" </dev/null; }

without_refresh() {
  awk 'BEGIN { RS = ";\n" } !/REFRESH/ { print $0 ";" }' "$@"
}

schema() {
  $CH --query "DROP DATABASE IF EXISTS $CH_DB" </dev/null
  CH_DB="$CH_DB" CH_CLIENT="$CH" PROJECTIONS=0 ./scripts/apply-schema.sh >/dev/null
  without_refresh ingest/siri.sql ingest/enrich.sql ingest/health.sql \
    | $CH --database "$CH_DB" --multiquery
}

# Each table's rows, as the SELECT that cuts them to OPERATORS.
declare -A CUT=(
  [gtfs_route]="SELECT * FROM gtfs_route WHERE operator_ref IN ($OPERATORS)"
  [gtfs_ride]="SELECT * FROM gtfs_ride WHERE gtfs_route_id IN (SELECT id FROM gtfs_route WHERE operator_ref IN ($OPERATORS))"
  [gtfs_ride_stop]="SELECT * FROM gtfs_ride_stop WHERE gtfs_ride_id IN (SELECT id FROM gtfs_ride WHERE gtfs_route_id IN (SELECT id FROM gtfs_route WHERE operator_ref IN ($OPERATORS)))"
  [gtfs_stop]="SELECT * FROM gtfs_stop WHERE id IN (SELECT gtfs_stop_id FROM gtfs_ride_stop WHERE gtfs_ride_id IN (SELECT id FROM gtfs_ride WHERE gtfs_route_id IN (SELECT id FROM gtfs_route WHERE operator_ref IN ($OPERATORS))))"
  [siri_route]="SELECT * FROM siri_route WHERE operator_ref IN ($OPERATORS)"
  [siri_ride]="SELECT * FROM siri_ride WHERE siri_route_id IN (SELECT id FROM siri_route WHERE operator_ref IN ($OPERATORS))"
  [siri_ride_stop]="SELECT * FROM siri_ride_stop WHERE siri_ride_id IN (SELECT id FROM siri_ride WHERE siri_route_id IN (SELECT id FROM siri_route WHERE operator_ref IN ($OPERATORS)))"
  [siri_stop]="SELECT * FROM siri_stop WHERE id IN (SELECT siri_stop_id FROM siri_ride_stop WHERE siri_ride_id IN (SELECT id FROM siri_ride WHERE siri_route_id IN (SELECT id FROM siri_route WHERE operator_ref IN ($OPERATORS))))"
  [siri_vehicle_location]="SELECT * FROM siri_vehicle_location WHERE siri_ride_stop_id IN (SELECT id FROM siri_ride_stop WHERE siri_ride_id IN (SELECT id FROM siri_ride WHERE siri_route_id IN (SELECT id FROM siri_route WHERE operator_ref IN ($OPERATORS))))"
  [siri_ride_duration]="SELECT * FROM siri_ride_duration WHERE siri_ride_id IN (SELECT id FROM siri_ride WHERE siri_route_id IN (SELECT id FROM siri_route WHERE operator_ref IN ($OPERATORS)))"
  [siri_snapshot]="SELECT * FROM siri_snapshot"
  [siri_snapshot_seen]="SELECT * FROM siri_snapshot_seen"
)

build() {
  schema
  read -r y m d <<<"${DAY//-/ }"
  CH_DB="$CH_DB" CH_CLIENT="$CH" ./ingest/gtfs.sh "$y" "$m" "$d"
  CH_DB="$CH_DB" CH_CLIENT="$CH" ./ingest/backfill.sh "$y" "$m" "$d" "$HOUR"
  ch --param_day="$DAY" --multiquery --queries-file ingest/enrich-once.sql
  cut
}

cut() {
  rm -f "$DIR"/*.native.zst
  for t in "${!CUT[@]}"; do
    ch --query "${CUT[$t]} ORDER BY tuple(*) INTO OUTFILE '$PWD/$DIR/$t.native.zst' FORMAT Native"
  done
  du -ch "$DIR"/*.native.zst | tail -1
}

load() {
  schema
  for f in "$DIR"/*.native.zst; do
    ch --query "INSERT INTO $(basename "$f" .native.zst) FROM INFILE '$PWD/$f' FORMAT Native"
  done
  # Derived, so measured here rather than shipped: computed before the cut it
  # would describe the whole day and not the rows the fixture holds.
  ch --param_day="$DAY" --query "INSERT INTO ingest_day_health SELECT * FROM ingest_day_health_src(day = {day:Date})"
  # gtfs_rides_agg_by_hour is derived and not shipped: refreshing it here is
  # what ingest would do, and it then holds exactly the fixture's operators.
  ch --query "SYSTEM REFRESH VIEW gtfs_rides_agg_by_hour_refresh"
  ch --query "SYSTEM WAIT VIEW gtfs_rides_agg_by_hour_refresh"
}

case "${1:-}" in
  build) build ;;
  cut) cut ;;
  load) load ;;
  *) echo "usage: $0 build|cut|load" >&2; exit 2 ;;
esac
