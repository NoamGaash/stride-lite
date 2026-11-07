#!/usr/bin/env bash
# Fills a new node with the whole history, once.
#
#   ./scripts/first-load.sh
#
# infra/bootstrap.sh starts this as a systemd unit at the end of a launch, and
# before it existed a deploy produced a working API over an empty database:
# the refreshable views in ingest/siri.sql poll the running hour, so data
# accumulated from go-live forward and nothing before it existed, and
# ingest/catchup.sh deliberately refuses an empty database ("a first load is
# ./up.sh, not a catch-up"). Nothing loaded history. This does.
#
# Five stages, each skipped when the state file says it finished:
#
#   history   everything up to the dump's last day — from a backup of ours if
#             there is one, otherwise from the public dump
#   gtfs      yesterday's feed, which the dump's own GTFS tables stop short of
#   live      ingest/siri.sql and ingest/enrich.sql: the chain that keeps the
#             database current from here on
#   backfill  the archive from the history watermark to today
#   publish   a backup to our own bucket, so no later instance repeats the
#             public rebuild
#
# history is first because a retry of it empties the data tables, and anything
# loaded before it would be emptied with them.
#
# The state file lives on the data volume, which is the right lifetime: it
# outlives the instance exactly as the data it describes does, so replacing the
# instance under the volume does not restart a load that already finished.
#
# It takes /var/lock/stride-catchup, the lock the hourly ingest/catchup.sh cron
# already uses with flock -n. So a catch-up tick during a first load does not
# run rather than queueing behind it, which is what we want: when the load
# finishes there is nothing left for that tick to do.
#
# Order is deliberate in one respect that is easy to undo by accident. The live
# chain is installed AFTER the history stage, not before, because the dump
# carries its own `id` values while the chain mints ids as max(id) +
# row_number(): the two running at once hand the same id to different rows,
# which is the failure that cost this project twenty-nine days of data. The
# backfill stage runs after the chain is up and does not need the same care,
# because ingest/backfill-range.sh stops and restarts the chain itself.
set -euo pipefail
cd "$(dirname "$0")/.."

CH_DB=${CH_DB:-stride}
CH=${CH_CLIENT:-clickhouse client}
STATE=${FIRST_LOAD_STATE:-/var/lib/clickhouse/first-load.state}
LOCK=${FIRST_LOAD_LOCK:-/var/lock/stride-catchup}
DUMP_URL=${DUMP_URL:-https://openbus-stride-public.s3.eu-west-1.amazonaws.com/stride_db.sql.zst}
# Where our own copy of the built database is, if we have one. Empty means the
# public rebuild, which is the path that needs no artefact from us and the path
# that costs Hasadna 154.63 GB of egress.
BACKUP_URL=${BACKUP_URL:-}
# Set when the bucket is ours to write as well as read: after a public rebuild
# this is what means the next instance restores in an hour instead.
BACKUP_PUBLISH=${BACKUP_PUBLISH:-$BACKUP_URL}

ch() { $CH --database "$CH_DB" "$@"; }

say() { printf '\n== %s\n' "$*"; }

# One line per stage, append-only, so the file reads as a log of what happened
# and when rather than only as a set of flags.
state_of() {
  [ -f "$STATE" ] || return 0
  awk -v s="$1" -F'\t' '$1 == s { v = $2 } END { print v }' "$STATE"
}

mark() {
  mkdir -p "$(dirname "$STATE")"
  printf '%s\t%s\t%s\n' "$1" "$2" "$(date -Is)" >> "$STATE"
}

# A stage runs when it has not finished. A stage that started and did not finish
# is a crash, and the function for it is responsible for being re-runnable.
stage() {
  local name=$1
  shift
  if [ "$(state_of "$name")" = "done" ]; then
    echo "$name: already done"
    return 0
  fi
  say "$name"
  mark "$name" started
  "$@"
  mark "$name" "done"
}

# The newest hour anything in the database was derived from. Both sources are
# consulted because each path populates a different one: the dump brings
# siri_snapshot, the archive brings siri_snapshot_seen. Not max(recorded_at_time)
# — 0.32% of that column is in the future and it answers 2038 (finding 14).
watermark() {
  ch --query "
    SELECT max(d) FROM (
        SELECT max(siri_snapshot_id) AS d FROM siri_snapshot_seen FINAL
        UNION ALL
        SELECT max(snapshot_id) FROM siri_snapshot)" | cut -d/ -f1-3 | tr / -
}

rows_loaded() { ch --query "SELECT count() FROM siri_vehicle_location"; }

# Called before an attempt at the history stage, and the reason the stage is
# re-runnable at all: RESTORE refuses a table that already holds rows (measured:
# CANNOT_RESTORE_TABLE), and a dump load that died half way leaves part of
# itself behind. Emptying first is safe here and only here, because this stage
# only runs when no load has ever finished on this volume.
clear_for_retry() {
  [ "$(rows_loaded)" != 0 ] || return 0
  echo "   a previous attempt left rows behind; emptying the data tables first"
  local t
  for t in $(ch --query "SELECT name FROM system.tables
                         WHERE database = '$CH_DB' AND engine LIKE '%MergeTree%'
                           AND name != 'schema_migrations' FORMAT TSV"); do
    ch --query "TRUNCATE TABLE \`$t\`"
  done
}

# On a first run there is no chain yet, because the live stage comes after this
# one — these two do nothing and the ordering is what keeps the load safe. They
# are here for the retry: a history stage that failed after the live stage
# finished re-runs with the chain already installed and refreshing, and the dump
# carries its own ids while the chain mints them as max(id) + row_number().
#
# This is ingest/backfill-range.sh's stop_views/restart_views, narrowed. It is
# duplicated rather than shared because ingest/ is not ours to edit;
# ingest/enrich-once.sql already refers to an ingest/chain-guard.sh, and when
# that lands this should call it instead.
stopped_views=""

pause_chain() {
  stopped_views=$(ch --query "
    SELECT view FROM system.view_refreshes
    WHERE database = '$CH_DB' AND status != 'Disabled' FORMAT TSV")
  [ -n "$stopped_views" ] || return 0
  local v
  for v in $stopped_views; do ch --query "SYSTEM STOP VIEW \`$v\`"; done
  # STOP prevents the next refresh and does not cancel the one in flight.
  local waited=0 running
  while :; do
    running=$(ch --query "
      SELECT count() FROM system.view_refreshes
      WHERE database = '$CH_DB' AND status = 'Running'")
    [ "$running" = 0 ] && break
    [ "$waited" -ge 1800 ] && { echo "a refresh has run for 30 min; not racing it" >&2; exit 1; }
    echo "   waiting for $running refresh(es) already in flight"
    sleep 30
    waited=$((waited + 30))
  done
  echo "   stopped the refresh chain for the duration of the load"
}

resume_chain() {
  [ -n "$stopped_views" ] || return 0
  local v
  for v in $stopped_views; do
    ch --query "SYSTEM START VIEW \`$v\`" || echo "   WARNING: could not restart $v" >&2
  done
  stopped_views=""
}

# Asked before restoring rather than inferred from a failed RESTORE, because
# the two cases need opposite responses and the exit code does not tell them
# apart: an absent backup means rebuild from public data, a broken one means
# stop and look. On the first instance ever the bucket exists and is empty, so
# the answer here is no and the public rebuild is what runs.
#
# Any failure — no aws CLI, no permission, no bucket — reads as "no backup",
# which is the safe direction: it costs a slow load and never a wrong one.
backup_exists() {
  [ -n "$BACKUP_URL" ] || return 1
  command -v aws > /dev/null || { echo "   no aws CLI, so treating the backup as absent"; return 1; }
  local rest=${BACKUP_URL#s3://} bucket prefix
  bucket=${rest%%/*}
  prefix=${rest#*/}
  [ "$prefix" = "$bucket" ] && prefix=""
  local n
  n=$(aws s3api list-objects-v2 --bucket "$bucket" --prefix "$prefix" \
        --max-keys 1 --query 'length(Contents)' --output text 2> /dev/null || echo None)
  [ "$n" != None ] && [ "$n" != 0 ]
}

load_history() {
  pause_chain
  clear_for_retry
  if backup_exists; then
    echo "restoring from $BACKUP_URL"
    CH_DB="$CH_DB" CH_CLIENT="$CH" ./scripts/backup.sh restore "$BACKUP_URL"
    mark source restore
  else
    echo "no copy of ours to restore; rebuilding from the public dump"
    echo "this reads 154,630,881,726 bytes out of Hasadna's bucket, once"
    CH_DB="$CH_DB" CH_CLIENT="$CH" ./scripts/load-from-dump.sh "$DUMP_URL"
    mark source dump
  fi
  resume_chain
}

install_live_chain() {
  ch --multiquery < ingest/siri.sql
  ch --multiquery < ingest/enrich.sql
  ch --multiquery < ingest/health.sql
  echo "refreshable views created; they schedule themselves from here"
}

backfill_the_gap() {
  local from
  from=$(watermark)
  [ -n "$from" ] || { echo "no watermark: the history stage loaded nothing" >&2; exit 1; }
  echo "archive from $from to today"
  CH_DB="$CH_DB" CH_CLIENT="$CH" ./ingest/backfill-range.sh "$from" "$(date -u +%F)"
}

# The copy ages, and nothing here refreshes it: a node that restored does not
# publish, so the backup stays as old as the instance that wrote it and a later
# instance has correspondingly more days to backfill. That is a cost in time and
# not in correctness, and the fix when it matters is to run
# `scripts/backup.sh save` by hand rather than to add a cron entry that rewrites
# the only copy on a schedule nobody is watching.
publish_backup() {
  if [ -z "$BACKUP_PUBLISH" ]; then
    echo "no bucket of ours to publish to; the next instance will rebuild from public data"
    return 0
  fi
  if [ "$(state_of source)" = restore ]; then
    echo "this node was restored from $BACKUP_URL; the copy there is the one it came from"
    return 0
  fi
  echo "publishing to $BACKUP_PUBLISH so no later instance repeats the public rebuild"
  CH_DB="$CH_DB" CH_CLIENT="$CH" ./scripts/backup.sh save "$BACKUP_PUBLISH"
}

gtfs_today() {
  CH_DB="$CH_DB" CH_CLIENT="$CH" ./ingest/gtfs.sh
}

# So a load that dies with the chain stopped does not leave it stopped.
trap resume_chain EXIT INT TERM

exec 9> "$LOCK"
if ! flock -n 9; then
  echo "another ingest run holds $LOCK; not starting a second one"
  exit 0
fi

# Refusing is the whole point of this check. A database with rows in it and no
# first load recorded is either a volume whose state file was lost or an
# operator running this on a working node; clear_for_retry would empty it.
loaded=$(rows_loaded)
if [ "$(state_of history)" = "" ] && [ "$loaded" != 0 ]; then
  echo "$CH_DB already holds $loaded vehicle locations and $STATE records no first load." >&2
  echo "Refusing, because a retry of the history stage empties the data tables." >&2
  echo "To load this volume from scratch anyway, say so explicitly: append a" >&2
  echo "tab-separated line reading history, started and a timestamp to $STATE." >&2
  exit 1
fi

stage history  load_history
stage gtfs     gtfs_today
stage live     install_live_chain
stage backfill backfill_the_gap
stage publish  publish_backup

say "where it stands"
ch --query "
  SELECT
      (SELECT max(siri_snapshot_id) FROM siri_snapshot_seen FINAL) AS newest_snapshot,
      (SELECT count() FROM siri_vehicle_location) AS vehicle_locations,
      (SELECT max(date) FROM gtfs_route) AS newest_gtfs_date,
      (SELECT formatReadableSize(sum(bytes_on_disk)) FROM system.parts
        WHERE database = '$CH_DB' AND active) AS on_disk
  FORMAT Vertical"
ch --query "
  SELECT table, command, parts_to_do
  FROM system.mutations
  WHERE database = '$CH_DB' AND NOT is_done FORMAT PrettyCompact"
