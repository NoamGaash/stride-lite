#!/usr/bin/env bash
# Loads the public Stride PostgreSQL dump into a local ClickHouse in a single
# streaming pass: one FIFO per table, 16 concurrent inserts, nothing staged on
# disk beyond what ClickHouse itself writes.
#
#   ./scripts/load-from-dump.sh /path/to/stride_db.sql.zst
#
# See docs/LOCAL-DB.md for prerequisites, expected runtime and verification.
set -euo pipefail

DUMP=${1:?usage: load-from-dump.sh <stride_db.sql.zst>}
CH_DB=${CH_DB:-stride}
CH=${CH_CLIENT:-clickhouse client}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export FIFO_DIR="$WORK/fifos"
mkdir -p "$FIFO_DIR"

# Column order is taken from the live schema rather than assumed, because the
# dump's COPY blocks are headerless and a mismatch loads silently and wrongly.
tables=$($CH --query "SELECT name FROM system.tables WHERE database='$CH_DB' ORDER BY name FORMAT TSV")
[ -n "$tables" ] || { echo "no tables in $CH_DB — apply db/schema.sql first" >&2; exit 1; }

pids=()
for t in $tables; do
  cols=$($CH --query "SELECT concat('\`', arrayStringConcat(groupArray(name), '\`, \`'), '\`')
                      FROM (SELECT name FROM system.columns
                            WHERE database='$CH_DB' AND table='$t' ORDER BY position) FORMAT TSV")
  mkfifo "$FIFO_DIR/$t"
  $CH --date_time_input_format=best_effort \
      --format_tsv_null_representation='\N' \
      --max_insert_block_size=1048576 \
      --query "INSERT INTO $CH_DB.\`$t\` ($cols) FORMAT TSV" \
      < "$FIFO_DIR/$t" &
  pids+=($!)
done

echo "load started $(date -Is) — 16 tables, ~13.7 billion rows"
zstd -dc "$DUMP" | mawk -f "$(dirname "$0")/split-tables.awk"
for p in "${pids[@]}"; do wait "$p"; done
echo "load finished $(date -Is)"

$CH --query "SELECT table, formatReadableQuantity(sum(rows)) AS rows,
                    formatReadableSize(sum(data_compressed_bytes)) AS size,
                    round(sum(data_compressed_bytes)/sum(rows), 2) AS bytes_per_row
             FROM system.parts WHERE database='$CH_DB' AND active
             GROUP BY table ORDER BY sum(data_compressed_bytes) DESC"
