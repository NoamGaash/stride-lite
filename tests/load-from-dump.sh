#!/usr/bin/env bash
# Runs scripts/load-from-dump.sh against a dump that streams slowly, as a user
# whose server-side timeouts are seconds instead of minutes, so the failures a
# real 150 GB load meets hours in show up here in under a minute:
#
# - a table whose data ends long before the dump does waits for EOF past
#   receive_timeout;
# - a table whose data starts long after the load began finds its connection
#   closed by idle_connection_timeout;
# - a retry's TRUNCATE meets a table over max_table_size_to_drop.
#
#   CH_CLIENT="clickhouse client" tests/load-from-dump.sh
set -euo pipefail
cd "$(dirname "$0")/.."
CH=${CH_CLIENT:-clickhouse client}
DB=load_from_dump_test
USER_=load_from_dump_test
GAP=10

$CH --multiquery --query "
  DROP DATABASE IF EXISTS $DB;
  DROP USER IF EXISTS $USER_;
  CREATE DATABASE $DB;
  CREATE TABLE $DB.artifact (id UInt32, note String) ENGINE = MergeTree ORDER BY id;
  CREATE TABLE $DB.ingest_day_health (day Date) ENGINE = MergeTree ORDER BY day;
  CREATE TABLE $DB.schema_migrations (name String) ENGINE = MergeTree ORDER BY name;
  CREATE TABLE $DB.siri_route (id UInt32, line_ref String) ENGINE = MergeTree ORDER BY id;
  CREATE TABLE $DB.siri_vehicle_location (id UInt32) ENGINE = MergeTree ORDER BY id;
  INSERT INTO $DB.siri_vehicle_location VALUES (99);
  INSERT INTO $DB.schema_migrations VALUES ('001_example.sql');
  CREATE USER $USER_ IDENTIFIED WITH no_password
    SETTINGS idle_connection_timeout = 3, receive_timeout = 3, max_table_size_to_drop = 1;
  GRANT CURRENT GRANTS ON *.* TO $USER_;"

dump() {
  printf 'SET statement_timeout = 0;\nCOPY public.artifact (id, note) FROM stdin;\n1\ta\\tb\n2\t\\N\n\\.\n' | zstd -qc
  sleep "$GAP"
  printf 'COPY public.siri_route (id, line_ref) FROM stdin;\n7\tx\n\\.\n' | zstd -qc
  sleep "$GAP"
  printf 'COPY public.siri_vehicle_location (id) FROM stdin;\n1\n2\n3\n\\.\n' | zstd -qc
}

rc=0
dump | CH_DB=$DB CH_CLIENT="$CH --user $USER_" ./scripts/load-from-dump.sh - || rc=$?

got=$($CH --query "
  SELECT concat(
    toString((SELECT count() FROM $DB.artifact)), ' ',
    toString((SELECT count() FROM $DB.siri_route)), ' ',
    toString((SELECT count() FROM $DB.siri_vehicle_location)), ' ',
    toString((SELECT count() FROM $DB.ingest_day_health)), ' ',
    toString((SELECT count() FROM $DB.schema_migrations)), ' ',
    (SELECT note FROM $DB.artifact WHERE id = 1))")
$CH --multiquery --query "DROP DATABASE $DB; DROP USER $USER_"

want='2 1 3 0 1 a\tb'
if [ "$rc" != 0 ] || [ "$got" != "$want" ]; then
  echo "FAIL: exit $rc, counts artifact/siri_route/siri_vehicle_location/ingest_day_health/schema_migrations and note: '$got', want '$want'" >&2
  exit 1
fi
echo "ok"
