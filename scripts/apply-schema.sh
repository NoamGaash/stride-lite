#!/usr/bin/env bash
# Creates the database, its 16 tables and the views the API reads. Idempotent.
set -euo pipefail
CH_DB=${CH_DB:-stride}
CH=${CH_CLIENT:-clickhouse client}
$CH --query "CREATE DATABASE IF NOT EXISTS $CH_DB"
sed "s/^CREATE TABLE stride\./CREATE TABLE IF NOT EXISTS $CH_DB./" "$(dirname "$0")/../db/schema.sql" \
  | $CH --multiquery
$CH --database "$CH_DB" --multiquery < "$(dirname "$0")/../db/views.sql"
$CH --query "SELECT count() AS tables FROM system.tables WHERE database='$CH_DB'"
