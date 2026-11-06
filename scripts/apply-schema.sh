#!/usr/bin/env bash
# Creates the database, its tables, the migrations that have not run, and the
# views the API reads. Idempotent, and the single entry point: infra/bootstrap.sh
# calls it on a new instance, scripts/deploy.sh on every push.
#
# The order is the point. Tables first, because a migration alters one. Migrations
# second, because a view may read a column one of them adds. Views last, and they
# are CREATE OR REPLACE, so the file is always what the database holds.
set -euo pipefail
CH_DB=${CH_DB:-stride}
CH=${CH_CLIENT:-clickhouse client}
here="$(cd "$(dirname "$0")" && pwd)"

$CH --query "CREATE DATABASE IF NOT EXISTS $CH_DB"
sed "s/^CREATE TABLE stride\./CREATE TABLE IF NOT EXISTS $CH_DB./" "$here/../db/schema.sql" \
  | $CH --multiquery
CH_CLIENT="$CH" CH_DB="$CH_DB" "$here/migrate.sh"
$CH --database "$CH_DB" --multiquery < "$here/../db/views.sql"
$CH --query "SELECT count() AS tables FROM system.tables WHERE database='$CH_DB'"
