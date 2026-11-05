#!/usr/bin/env bash
# One command: from an empty directory to an API serving live data.
#
#   ./up.sh              two hours of live SIRI, then keeps itself current
#   ./up.sh 6            six hours of history instead of two
#   ./up.sh 0            no backfill; only start and let the loop fill forward
#
# No Docker, no root, no credentials, no scheduler. The data is public.
#
# This is deliberately polite about the machine it runs on: ClickHouse is
# started with a memory ceiling, I/O bandwidth limits, a merge-size cap and six
# of the available cores, because the reference machine for this project is
# somebody's workstation and not a server. See ingest/local.xml. On a dedicated
# box, delete that file or raise the numbers.
set -euo pipefail
cd "$(dirname "$0")"

HOURS=${1:-2}
CH_DB=${CH_DB:-stride}
CH_HTTP_PORT=${CH_HTTP_PORT:-8123}
CH_TCP_PORT=${CH_TCP_PORT:-9000}
CH_HTTP=${CH_HTTP:-http://127.0.0.1:$CH_HTTP_PORT}
STATE=${STATE:-$PWD/.stride-lite}
PORT=${PORT:-8080}

say() { printf '\n== %s\n' "$*"; }

say "ClickHouse binary"
if [ -x ./clickhouse ]; then
  echo "already here: $(./clickhouse local --query 'SELECT version()')"
else
  curl -sSL https://clickhouse.com/ | sh
fi
CH="./clickhouse client --port $CH_TCP_PORT"

say "server"
if curl -sf "$CH_HTTP/ping" >/dev/null 2>&1; then
  echo "already listening on $CH_HTTP"
else
  mkdir -p "$STATE"
  sed -e "s|__STATE__|$STATE|g" -e "s|__TCP_PORT__|$CH_TCP_PORT|" -e "s|__HTTP_PORT__|$CH_HTTP_PORT|" ingest/local.xml > "$STATE/config.xml"
  cp ingest/local-users.xml "$STATE/users.xml"
  ./clickhouse server --config-file="$STATE/config.xml" --daemon
  for _ in $(seq 60); do curl -sf "$CH_HTTP/ping" >/dev/null 2>&1 && break; sleep 1; done
  curl -sf "$CH_HTTP/ping" >/dev/null || { echo "server did not come up; see $STATE/ch.err.log" >&2; exit 1; }
  echo "started, state in $STATE"
fi

say "schema"
CH_CLIENT="$CH" CH_DB="$CH_DB" ./scripts/apply-schema.sh
$CH --database "$CH_DB" --multiquery < db/raw.sql

say "ingest and enrichment"
$CH --database "$CH_DB" --multiquery < ingest/siri.sql
$CH --database "$CH_DB" --multiquery < ingest/enrich.sql
echo "refreshable views created; they schedule themselves from here"

say "GTFS, yesterday's feed"
# The one piece that needs something outside the database: ClickHouse cannot
# read a multi-file zip, so the feed has to be fetched and unpacked by a shell.
# A line in cron keeps it current:
#
#   17 4 * * *  cd /path/to/stride-lite && CH_DB=stride ./ingest/gtfs.sh
#
CH_DB="$CH_DB" CH_CLIENT="$CH" ./ingest/gtfs.sh || echo "   GTFS load failed; SIRI is unaffected"

if [ "$HOURS" -gt 0 ]; then
  say "backfilling $HOURS hour(s)"
  # Oldest first: a ride's scheduled_start_time is taken from its earliest
  # observation, so loading forwards gets the same answer the live loop would.
  for i in $(seq "$HOURS" -1 1); do
    stamp=$(date -u -d "$i hours ago" +'%Y %m %d %H')
    # shellcheck disable=SC2086
    CH_DB="$CH_DB" CH_CLIENT="$CH" ./ingest/backfill.sh $stamp
  done
  say "enriching what was backfilled"
  $CH --database "$CH_DB" --multiquery < ingest/enrich-once.sql
fi

say "where it stands"
$CH --database "$CH_DB" --query "
  SELECT 'siri_vehicle_location' AS table, count() AS rows, max(recorded_at_time) AS latest
  FROM siri_vehicle_location
  UNION ALL
  SELECT 'raw', count(), max(recorded_at_time) FROM siri_vehicle_location_raw
  FORMAT PrettyCompact"

say "API"
( cd api && npm ci --silent )
echo "starting on :$PORT — stop with ctrl-c"
cd api && CH_URL="$CH_HTTP" CH_DB="$CH_DB" PORT="$PORT" npm start
