#!/usr/bin/env bash
# Loads the public Stride PostgreSQL dump into a local ClickHouse in a single
# streaming pass: one FIFO per table, one insert each, nothing staged on disk
# beyond what ClickHouse itself writes.
#
#   ./scripts/load-from-dump.sh /path/to/stride_db.sql.zst
#   ./scripts/load-from-dump.sh https://…/stride_db.sql.zst   # never touches disk
#   ./scripts/load-from-dump.sh -                             # from stdin
#
# A URL is the form a cloud first load uses, and not for convenience: the dump
# is 144.01 GiB compressed and loads to 254.57 GiB, which together do not fit on
# the 350 GB (326 GiB) volume infra/main.tf provisions. Staging it is not slower
# there, it is impossible. The cost of streaming is that an interrupted load
# cannot resume — it starts over, and over somebody else's egress bill, which is
# why scripts/first-load.sh prefers restoring a backup we already hold.
#
# See docs/LOCAL-DB.md for prerequisites, expected runtime and verification.
set -euo pipefail

SRC=${1:?usage: load-from-dump.sh <stride_db.sql.zst | URL | ->}
CH_DB=${CH_DB:-stride}
CH=${CH_CLIENT:-clickhouse client}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export FIFO_DIR="$WORK/fifos"
mkdir -p "$FIFO_DIR"

# MergeTree tables only. The database also holds the ingest chain's views, and
# a FIFO named after a view would be an INSERT into something that refuses one.
tables=$($CH --query "SELECT name FROM system.tables
                      WHERE database='$CH_DB' AND engine LIKE '%MergeTree%'
                      ORDER BY name FORMAT TSV")
[ -n "$tables" ] || { echo "no tables in $CH_DB — apply db/schema.sql first" >&2; exit 1; }

# Truncated first, every run: this is re-run by systemd's Restart=on-failure
# on exactly the failure this script is prone to (the server closing a
# connection mid-stream), and an INSERT after a partial previous attempt does
# not replace those rows -- MergeTree keeps whatever already landed, so a
# retry piled a second copy of however much got through on top of the first.
# That surfaced as the data volume filling up earlier on each successive
# retry, not later: the disk was carrying duplicate history before the
# attempt doing the filling had written a byte of its own. Truncating first
# makes a retry mean what it says.
# max_table_size_to_drop: ClickHouse refuses TRUNCATE above 50 GB by default,
# which siri_vehicle_location always is after a partial attempt.
# schema_migrations is not dump data: it records the ALTERs this schema has
# had, and emptying it would make the next deploy replay them.
for t in $tables; do
  [ "$t" = schema_migrations ] && continue
  $CH --query "TRUNCATE TABLE $CH_DB.\`$t\` SETTINGS max_table_size_to_drop = 0"
done

# Exit code 108 is NO_DATA_TO_INSERT, which here means the dump carries no COPY
# block for this table. That is the normal case for every table this project
# added beyond the 16 the dump holds — the landing table, siri_ride_duration,
# ingest_day_health, schema_migrations — so it is not a failure. Anything else
# is, and its stderr is kept rather than discarded with it.
insert_one() {
  local t=$1 cols=$2 rc=0 first
  # Two timeouts, one per side of a table's data:
  # - before it: the client connects at once but sends nothing until stdin has
  #   data, and the server drops a connection idle for idle_connection_timeout
  #   (3600 s). Tables late in the dump wait longer than that, so the client is
  #   started only once the first line arrives.
  # - after it: the holder fds below keep every FIFO open until the whole dump
  #   has streamed, so an early table waits hours for EOF. receive_timeout
  #   (300 s by default) would kill it.
  # No first line means no COPY block for this table, which is not a failure:
  # see NO_DATA_TO_INSERT above.
  {
    IFS= read -r first || return 0
    { printf '%s\n' "$first"; cat; } \
      | $CH --receive_timeout=172800 \
            --date_time_input_format=best_effort \
            --format_tsv_null_representation='\N' \
            --max_insert_block_size=1048576 \
            --query "INSERT INTO $CH_DB.\`$t\` ($cols) FORMAT TSV" \
            2> "$WORK/$t.err" || rc=$?
  } < "$FIFO_DIR/$t"
  [ "$rc" -eq 108 ] && return 0
  [ "$rc" -eq 0 ] || cat "$WORK/$t.err" >&2
  return "$rc"
}

pids=()
holders=()
for t in $tables; do
  # Column order is taken from the live schema rather than assumed, because the
  # dump's COPY blocks are headerless and a mismatch loads silently and wrongly.
  cols=$($CH --query "SELECT concat('\`', arrayStringConcat(groupArray(name), '\`, \`'), '\`')
                      FROM (SELECT name FROM system.columns
                            WHERE database='$CH_DB' AND table='$t' ORDER BY position) FORMAT TSV")
  mkfifo "$FIFO_DIR/$t"
  insert_one "$t" "$cols" &
  pids+=($!)
  # A second writer, held open here and never written to, so that a table the
  # dump has no COPY block for still reaches EOF. Without it such a table
  # deadlocks the whole load: opening a FIFO for reading blocks until a writer
  # appears, so the insert never starts and the final `wait` never returns.
  # Reproduced before this was added, and it is not a corner case — it is every
  # table this project added beyond the dump's own.
  exec {fd}> "$FIFO_DIR/$t"
  holders+=("$fd")
done

echo "load started $(date -Is) — $(echo "$tables" | wc -w) tables"
case $SRC in
  # Deliberately no --retry: without -C - curl restarts a failed transfer from
  # byte zero, and the first attempt's bytes are already down the pipe and
  # inside zstd. A retry here would not heal the stream, it would corrupt it.
  http://*|https://*) curl -sSfL "$SRC" ;;
  -)                  cat ;;
  *)                  cat -- "$SRC" ;;
esac | zstd -dc | "$(command -v mawk || command -v awk)" -f "$(dirname "$0")/split-tables.awk"

for fd in "${holders[@]}"; do eval "exec $fd>&-"; done
for p in "${pids[@]}"; do wait "$p"; done
echo "load finished $(date -Is)"

# Tolerating 108 above is what makes an empty load possible to miss, so it is
# asserted instead. An empty siri_vehicle_location after a load that reported
# success means the stream carried no COPY block for it, which is a truncated
# or wrong source and not a dump.
test "$($CH --query "SELECT count() FROM $CH_DB.siri_vehicle_location")" != 0 || {
  echo "loaded nothing into siri_vehicle_location: $SRC is not the dump, or was truncated" >&2
  exit 1
}

# `AS rows` would shadow system.parts.rows and bytes_per_row would then divide
# by a String, which ClickHouse 26.10 rejects outright.
$CH --query "SELECT table, formatReadableQuantity(sum(rows)) AS row_count,
                    formatReadableSize(sum(data_compressed_bytes)) AS size,
                    round(sum(data_compressed_bytes)/sum(rows), 2) AS bytes_per_row
             FROM system.parts WHERE database='$CH_DB' AND active
             GROUP BY table ORDER BY sum(data_compressed_bytes) DESC"
