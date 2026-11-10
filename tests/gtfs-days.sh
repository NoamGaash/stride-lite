#!/usr/bin/env bash
# Which days ingest/gtfs.sh fetches when run with no arguments, against a
# ClickHouse that already holds one of them and a curl that records the URL and
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
$CH --multiquery --query "
  DROP DATABASE IF EXISTS $DB;
  CREATE DATABASE $DB;
  CREATE TABLE $DB.gtfs_route (id Int32, date Nullable(Date32)) ENGINE = MergeTree ORDER BY id;
  INSERT INTO $DB.gtfs_route VALUES (1, '$(date -u -d yesterday +%F)');" </dev/null

rc=0
PATH="$BIN:$PATH" CH_DB=$DB CH_CLIENT="$CH" ./ingest/gtfs.sh >/dev/null 2>&1 || rc=$?
got=$(sed -E 's#.*/gtfs_archive/([0-9/]+)/.*#\1#' "$BIN/urls" 2>/dev/null | sort | tr '\n' ' ')
want="$(day '2 days ago') $(day today) "

[ "$got" = "$want" ] || { echo "FAIL: fetched '$got', want '$want' (today and the day before yesterday, not yesterday, which is loaded)" >&2; exit 1; }
[ "$rc" != 0 ] || { echo "FAIL: every fetch failed and the script still exited 0" >&2; exit 1; }
echo ok
