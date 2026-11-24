#!/usr/bin/env bash
# db/migrations/004_seed_gtfs_links_from_the_dump.sql against a scratch
# database on a running ClickHouse: dump rides' links reach siri_ride_gtfs,
# a date the live ingest has seen is left to enrich_gtfs_link, and a second
# run adds nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
CH=${CH_CLIENT:-clickhouse client}
DB=seed_links_test
fail() { echo "FAIL: $*" >&2; exit 1; }
q() { $CH --database "$DB" --query "$1"; }
$CH --query "DROP DATABASE IF EXISTS $DB"; $CH --query "CREATE DATABASE $DB"
trap '$CH --query "DROP DATABASE IF EXISTS $DB"' EXIT
CH_DB=$DB CH_CLIENT="$CH" PROJECTIONS=0 ./scripts/apply-schema.sh >/dev/null

# 1: a 2024 dump ride with production's links. 2: a dump ride with none.
# 3: a ride on a date the live ingest has seen. 4: already linked.
q "INSERT INTO siri_ride (id, journey_ref, scheduled_start_time, route_gtfs_ride_id, gtfs_ride_id, scheduled_time_gtfs_ride_id) VALUES
   (1, '2024-08-14-0', '2024-08-14 08:00:00', 83891036, 83891036, 83891036),
   (2, '2024-08-14-1', '2024-08-14 08:00:00', NULL, NULL, NULL),
   (3, '2026-11-20-0', '2026-11-20 08:00:00', 7, 7, 7),
   (4, '2026-05-20-0', '2026-05-20 08:00:00', 9, 9, 9)"
q "CREATE TABLE IF NOT EXISTS siri_snapshot_seen (siri_snapshot_id String) ENGINE = ReplacingMergeTree ORDER BY siri_snapshot_id"
q "INSERT INTO siri_snapshot_seen VALUES ('2026/11/20/08/00')"
q "INSERT INTO siri_ride_gtfs (siri_ride_id, journey_date, gtfs_ride_id) VALUES (4, '2026-05-20', 9)"

run() { q "DELETE FROM schema_migrations WHERE name = '004_seed_gtfs_links_from_the_dump.sql'" >/dev/null
        CH_DB=$DB CH_CLIENT="$CH" ./scripts/migrate.sh >/dev/null; }
run
got=$(q "SELECT gtfs_ride_id, scheduled_time_gtfs_ride_id, journey_date FROM siri_ride_gtfs WHERE siri_ride_id = 1" | tr '\t' ' ')
[ "$got" = "83891036 83891036 2024-08-14" ] || fail "the dump ride's link was not carried over: '$got'"
[ "$(q "SELECT count() FROM siri_ride_gtfs WHERE siri_ride_id = 2")" = 0 ] || fail "a ride with no link got a row"
[ "$(q "SELECT count() FROM siri_ride_gtfs WHERE siri_ride_id = 3")" = 0 ] || fail "a date the live linker owns was seeded"
[ "$(q "SELECT count() FROM siri_ride_gtfs WHERE siri_ride_id = 4")" = 1 ] || fail "an already linked ride was duplicated"
run
[ "$(q "SELECT count() FROM siri_ride_gtfs")" = 2 ] || fail "a second run inserted again"
echo "seed-gtfs-links: ok"
