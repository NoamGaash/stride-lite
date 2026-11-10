#!/usr/bin/env bash
# Creates the database, its tables, the migrations that have not run, the views
# the API reads, and the projections it needs. Idempotent, and the single entry
# point: infra/bootstrap.sh calls it on a new instance, scripts/deploy.sh on
# every push, up.sh locally.
#
# The order is the point. Tables first, because a migration alters one. Migrations
# second, because a view may read a column one of them adds. Views next, and they
# are CREATE OR REPLACE, so the file is always what the database holds.
#
# Projections last, and their declaration separated from their filling, because
# filling one is the only step here that is not cheap. `MATERIALIZE PROJECTION`
# rewrites every active part of the table, and measured on ClickHouse 26.10 it
# does that even when the projection is already present and complete: a
# 1,000,000-row part went from all_1_1_0 to all_1_1_0_2 on a second MATERIALIZE.
# db/projections.sql ends with four of them, so applying that file as-is on every
# deploy rebuilt 74 GiB of projections every time — tens of minutes each by the
# file's own measurement, on a volume with 61 GiB spare. So the ADDs are applied
# from the file (metadata only, and IF NOT EXISTS) and the MATERIALIZEs are
# issued here, only for a (table, projection) pair some active part is missing.
set -euo pipefail
CH_DB=${CH_DB:-stride}
CH=${CH_CLIENT:-clickhouse client}
here="$(cd "$(dirname "$0")" && pwd)"

$CH --query "CREATE DATABASE IF NOT EXISTS $CH_DB"
sed "s/^CREATE TABLE stride\./CREATE TABLE IF NOT EXISTS $CH_DB./" "$here/../db/schema.sql" \
  | $CH --multiquery
$CH --database "$CH_DB" --multiquery < "$here/../db/raw.sql"
CH_CLIENT="$CH" CH_DB="$CH_DB" "$here/migrate.sh"
$CH --database "$CH_DB" --multiquery < "$here/../db/views.sql"
# PROJECTIONS=0 skips all of it. bootstrap.sh passes that because a projection
# declared before the first load is built during the insert, over parts not yet
# merged: on the 344 GB node, gtfs_ride_stop alone reached ~95 GB of data plus
# ~50 GB of projection mid-insert and the volume filled. deploy.sh runs this
# with the default once first-load.sh releases the lock, and builds them then.
if [ "${PROJECTIONS:-1}" = 1 ]; then
  grep -v '^[[:space:]]*ALTER TABLE .* MATERIALIZE PROJECTION' "$here/../db/projections.sql" \
    | $CH --database "$CH_DB" --multiquery

  # system.parts.projections is the projections a part actually carries, so this
  # asks the data rather than a bookkeeping table: a projection declared but never
  # filled, and one filled before a later part arrived, both show up here.
  #
  # A MATERIALIZE still running leaves its parts looking unfilled until it ends,
  # and a deploy in those hours would queue a second one that rewrites every part
  # again — so a pair with an unfinished MATERIALIZE is not pending, it is busy.
  pending=$($CH --database "$CH_DB" --query "
    SELECT DISTINCT pr.table, pr.name
    FROM system.projections AS pr
    INNER JOIN system.parts AS p ON p.database = pr.database AND p.table = pr.table
    WHERE pr.database = '$CH_DB' AND p.active AND NOT has(p.projections, pr.name)
      AND (pr.table, pr.name) NOT IN (
        SELECT table, extract(command, 'MATERIALIZE PROJECTION \\x60?(\\w+)')
        FROM system.mutations
        WHERE database = '$CH_DB' AND NOT is_done
          AND command LIKE '%MATERIALIZE PROJECTION%')
    ORDER BY pr.table, pr.name FORMAT TSV")

  if [ -z "$pending" ]; then
    echo "projections: none to start (complete, or still materialising)"
  else
    # Asynchronous on purpose: these are mutations measured in tens of minutes
    # each, and the API serves correct answers from the base tables while they
    # run — slower on the endpoints the projection is for, and only those.
    # system.mutations is where the progress is.
    while IFS=$'\t' read -r table projection; do
      echo "projections: materialising $table.$projection"
      $CH --database "$CH_DB" --query "ALTER TABLE \`$table\` MATERIALIZE PROJECTION \`$projection\`"
    done <<< "$pending"
  fi
fi

$CH --query "SELECT count() AS tables FROM system.tables WHERE database='$CH_DB'"
