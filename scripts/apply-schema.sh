#!/usr/bin/env bash
# Creates the database and its 16 tables. Idempotent.
set -euo pipefail
CH_DB=${CH_DB:-stride}
CH=${CH_CLIENT:-clickhouse client}
$CH --query "CREATE DATABASE IF NOT EXISTS $CH_DB"
sed "s/^CREATE TABLE stride\./CREATE TABLE IF NOT EXISTS $CH_DB./" "$(dirname "$0")/../db/schema.sql" \
  | $CH --multiquery
$CH --query "SELECT count() AS tables FROM system.tables WHERE database='$CH_DB'"
