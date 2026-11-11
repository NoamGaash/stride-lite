#!/usr/bin/env bash
# Which days ingest/gtfs.sh fetches when run with no arguments, against a
# ClickHouse seeded with SIRI and GTFS days and a curl that records what it is
# asked for, so nothing is downloaded from the archive.
#
#   CH_CLIENT="clickhouse client" tests/gtfs-days.sh
set -euo pipefail
cd "$(dirname "$0")/.."
CH=${CH_CLIENT:-clickhouse client}
DB=gtfs_days_test
BIN=$(mktemp -d); trap 'rm -rf "$BIN"; $CH --query "DROP DATABASE IF EXISTS $DB" </dev/null' EXIT

day() { date -u -d "$1" +%Y/%m/%d; }
NOT_ARCHIVED=$(day '1 day ago')

# HEAD (-I) answers whether the archive has a day: every day but NOT_ARCHIVED.
# A download (GET) is recorded and fails.
cat > "$BIN/curl" <<STUB
#!/bin/sh
url=""; head=0
for a; do case "\$a" in --head|-[!-]*I*) head=1 ;; https://*) url=\$a ;; esac; done
day=\$(echo "\$url" | sed -E 's#.*/gtfs_archive/([0-9/]+)/.*#\1#')
if [ \$head = 1 ]; then
  echo "\$day" >> "$BIN/heads"
  [ "\$day" = "$NOT_ARCHIVED" ] && exit 22
  exit 0
fi
echo "\$day" >> "$BIN/gets"
exit 22
STUB
chmod +x "$BIN/curl"

# Seeds SIRI on the given days and GTFS on the given days, runs the script, and
# sets $gets (days downloaded, in order) and $rc.
run() {
  local siri=$1 gtfs=$2 d values=""
  rm -f "$BIN/gets" "$BIN/heads"; touch "$BIN/gets" "$BIN/heads"
  IFS=, read -ra siri_days <<<"$siri"
  for d in "${siri_days[@]}"; do values+="('$(day "$d")/08/00'),"; done
  local gtfs_values=""
  IFS=, read -ra gtfs_days <<<"$gtfs"
  for d in "${gtfs_days[@]}"; do gtfs_values+="(1, '$(date -u -d "$d" +%F)'),"; done
  $CH --multiquery --query "
    DROP DATABASE IF EXISTS $DB;
    CREATE DATABASE $DB;
    CREATE TABLE $DB.siri_snapshot_seen (siri_snapshot_id String) ENGINE = ReplacingMergeTree ORDER BY siri_snapshot_id;
    CREATE TABLE $DB.gtfs_route (id Int32, date Nullable(Date32)) ENGINE = MergeTree ORDER BY id;
    ${values:+INSERT INTO $DB.siri_snapshot_seen VALUES ${values%,};}
    ${gtfs_values:+INSERT INTO $DB.gtfs_route VALUES ${gtfs_values%,};}" </dev/null
  rc=0
  PATH="$BIN:$PATH" CH_DB=$DB CH_CLIENT="$CH" ./ingest/gtfs.sh > "$BIN/out" 2>&1 || rc=$?
  gets=$(tr '\n' ' ' < "$BIN/gets")
}

# A hole behind the newest GTFS day is the case that matters: the first load
# brought SIRI up to date and GTFS only for its last day. The day the archive
# lacks is skipped, the newest real hole is fetched, its failure stops the run
# before anything older, and nothing is staged from a failed download.
run "10 days ago, 2 days ago, 1 day ago, today" "2 days ago, today"
want="$(day '10 days ago') "
[ "$gets" = "$want" ] || { cat "$BIN/out"; echo "FAIL: downloaded '$gets', want '$want'" >&2; exit 1; }
grep -qx "$NOT_ARCHIVED" "$BIN/heads" || { echo "FAIL: never asked the archive about $NOT_ARCHIVED" >&2; exit 1; }
[ "$rc" != 0 ] || { echo "FAIL: the download failed and the script still exited 0" >&2; exit 1; }
others=$($CH --query "SELECT count() FROM system.tables WHERE database = '$DB' AND name NOT IN ('gtfs_route', 'siri_snapshot_seen')" </dev/null)
[ "$others" = 0 ] || { echo "FAIL: a failed download went on to stage and load ($others tables created)" >&2; exit 1; }

# Newest first: the days people look at are the recent ones, and a long hole
# takes several runs to fill.
run "10 days ago, 5 days ago, today" "today"
want="$(day '5 days ago') "
[ "$gets" = "$want" ] || { echo "FAIL: with a hole of two days, fetched '$gets' first, want the newer '$want'" >&2; exit 1; }

# Today is loaded even before any SIRI for it has landed.
run "" ""
want="$(day today) "
[ "$gets" = "$want" ] || { echo "FAIL: with nothing loaded, downloaded '$gets', want today '$want'" >&2; exit 1; }

# Every SIRI day has its GTFS: nothing to ask, nothing to fetch.
run "5 days ago, today" "5 days ago, today"
if [ -n "$gets" ] || [ -s "$BIN/heads" ] || [ "$rc" != 0 ]; then
  echo "FAIL: up to date, yet asked '$(tr '\n' ' ' < "$BIN/heads")', fetched '$gets', exited $rc" >&2; exit 1
fi
echo ok
