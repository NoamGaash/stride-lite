#!/usr/bin/env bash
# Applies db/migrations/*.sql once each, in filename order.
#
# Why this exists at all: db/schema.sql creates tables with IF NOT EXISTS, which
# converges a new database and cannot change an existing one. Measured on
# ClickHouse 26.10 — a changed body under IF NOT EXISTS is accepted and silently
# discarded, so the file and the database drift with nothing to say so. Views get
# out of that by being replaced outright on every deploy; a table holds data and
# cannot be, so a table change is an ALTER that has to run exactly once. This is
# the record of which ones have.
#
# There is no transaction around a migration: ClickHouse DDL does not roll back.
# So write each statement to be safe to re-run after a failure half way — ADD
# COLUMN IF NOT EXISTS, DROP COLUMN IF EXISTS — and a retry then finishes the job
# rather than failing on the part that already landed.
set -euo pipefail

CH_DB=${CH_DB:-stride}
CH=${CH_CLIENT:-clickhouse client}
here="$(cd "$(dirname "$0")" && pwd)"
dir="$here/../db/migrations"

ch() { $CH --database "$CH_DB" "$@"; }

ch --query "
  CREATE TABLE IF NOT EXISTS schema_migrations
  (
      name       String,
      applied_at DateTime DEFAULT now()
  )
  ENGINE = MergeTree
  ORDER BY name"

shopt -s nullglob
applied=0
for f in "$dir"/*.sql; do
  name=$(basename "$f")
  if [ "$(ch --query "SELECT count() FROM schema_migrations WHERE name = '$name'")" != 0 ]; then
    continue
  fi
  echo "migrating: $name"
  ch --multiquery < "$f"
  # </dev/null is not decoration: clickhouse client given an INSERT ... VALUES
  # through --query still reads stdin for more rows, so without it this waits
  # forever and every deploy with a pending migration hangs.
  ch --query "INSERT INTO schema_migrations (name) VALUES ('$name')" < /dev/null
  applied=$((applied + 1))
done
echo "migrations applied: $applied"
