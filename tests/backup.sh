#!/usr/bin/env bash
# Runs scripts/backup.sh save and restore against a local S3 (moto) with a
# static key, the way a node outside AWS has to sign. Checks that every request
# was signed with that key, and that the secret reached neither the query log
# nor any process's command line.
#
#   S3=http://127.0.0.1:5000 CH_CLIENT="clickhouse client" tests/backup.sh
set -euo pipefail
cd "$(dirname "$0")/.."
CH=${CH_CLIENT:-clickhouse client}
S3=${S3:?a moto server, e.g. http://127.0.0.1:5000}
DB=backup_test
BUCKET=stride-backup-test
URL="$S3/$BUCKET/run-$(date +%s)/"
export AWS_ACCESS_KEY_ID=AKIABACKUPTEST000001
export AWS_SECRET_ACCESS_KEY=backup-test-secret-$RANDOM$RANDOM

curl -sf -X PUT "$S3/$BUCKET" > /dev/null || true
curl -sf -X POST "$S3/moto-api/recorder/reset-recording" > /dev/null
curl -sf -X POST "$S3/moto-api/recorder/start-recording" > /dev/null

$CH --multiquery --query "
  DROP DATABASE IF EXISTS $DB;
  CREATE DATABASE $DB;
  CREATE TABLE $DB.t (id UInt32) ENGINE = MergeTree ORDER BY id;
  INSERT INTO $DB.t SELECT number FROM numbers(1000);"

CH_DB=$DB CH_CLIENT="$CH" scripts/backup.sh save "$URL" &
pid=$!
leaked=0
while kill -0 "$pid" 2> /dev/null; do
  grep -qs -- "$AWS_SECRET_ACCESS_KEY" /proc/[0-9]*/cmdline && leaked=1
  sleep 0.05
done
wait "$pid"

$CH --query "DROP TABLE $DB.t SYNC"
$CH --query "CREATE TABLE $DB.t (id UInt32) ENGINE = MergeTree ORDER BY id"
CH_DB=$DB CH_CLIENT="$CH" scripts/backup.sh restore "$URL"

fail=0
rows=$($CH --query "SELECT count() FROM $DB.t")
[ "$rows" = 1000 ] || { echo "FAIL: restored $rows rows, expected 1000"; fail=1; }

recording=$(curl -sf "$S3/moto-api/recorder/download-recording")
total=$(grep -c . <<< "$recording" || true)
signed=$(grep -c "Credential=$AWS_ACCESS_KEY_ID/" <<< "$recording" || true)
if [ "$total" = 0 ] || [ "$signed" != "$total" ]; then
  echo "FAIL: $signed of $total S3 requests were signed with the key"; fail=1
fi

$CH --query "SYSTEM FLUSH LOGS"
logged=$($CH --param_s="$AWS_SECRET_ACCESS_KEY" --query \
  "SELECT count() FROM system.query_log WHERE position(query, {s:String}) > 0 AND query NOT LIKE '%system.query_log%'")
[ "$logged" = 0 ] || { echo "FAIL: the secret is in system.query_log $logged times"; fail=1; }
[ "$leaked" = 0 ] || { echo "FAIL: the secret was on a process's command line"; fail=1; }

$CH --query "DROP DATABASE $DB"
[ "$fail" = 0 ] && echo "backup: signed with the static key, secret kept out of logs and argv"
exit "$fail"
