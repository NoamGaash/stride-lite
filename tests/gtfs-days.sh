#!/usr/bin/env bash
# Which days ingest/gtfs.sh fetches when run with no arguments, against a
# ClickHouse whose newest GTFS day is given and a curl that records the URL and
# fails, so nothing is downloaded from the archive.
#
#   CH_CLIENT="clickhouse client" tests/gtfs-days.sh
set -euo pipefail
cd "$(dirname "$0")/.."
CH=${CH_CLIENT:-clickhouse client}
DB=gtfs_days_test
BIN=$(mktemp -d); trap 'rm -rf "$BIN"; $CH --query "DROP DATABASE IF EXISTS $DB" </dev/null' EXIT
cat > "$BIN/curl" <<STUB
#!/bin/sh
for a; do case "\$a" in https://*) echo "\$a" >> "$BIN/urls" ;; esac; done
exit 22
STUB
chmod +x "$BIN/curl"

day() { date -u -d "$1" +%Y/%m/%d; }

# Seeds gtfs_route with one day, runs the script and sets $got (fetched days)
# and $rc.
run_with_newest() {
  rm -f "$BIN/urls"
  $CH --multiquery --query "
    DROP DATABASE IF EXISTS $DB;
    CREATE DATABASE $DB;
    CREATE TABLE $DB.gtfs_route (id Int32, date Nullable(Date32)) ENGINE = MergeTree ORDER BY id;
    INSERT INTO $DB.gtfs_route VALUES (1, '$(date -u -d "$1" +%F)');" </dev/null
  rc=0
  PATH="$BIN:$PATH" CH_DB=$DB CH_CLIENT="$CH" ./ingest/gtfs.sh >/dev/null 2>&1 || rc=$?
  touch "$BIN/urls"
  got=$(sed -E 's#.*/gtfs_archive/([0-9/]+)/.*#\1#' "$BIN/urls" | tr '\n' ' ')
}

# Switched off for two weeks: resumes the day after the newest loaded, and stops
# at the first failure instead of skipping past it and leaving a hole.
run_with_newest '15 days ago'
want="$(day '14 days ago') "
[ "$got" = "$want" ] || { echo "FAIL: fetched '$got', want '$want'" >&2; exit 1; }
others=$($CH --query "SELECT count() FROM system.tables WHERE database = '$DB' AND name != 'gtfs_route'" </dev/null)
[ "$others" = 0 ] || { echo "FAIL: a failed download went on to stage and load ($others tables created)" >&2; exit 1; }
[ "$rc" != 0 ] || { echo "FAIL: the fetch failed and the script still exited 0" >&2; exit 1; }

run_with_newest today
if [ -n "$got" ] || [ "$rc" != 0 ]; then
  echo "FAIL: up to date, yet fetched '$got' and exited $rc" >&2; exit 1
fi
echo ok
