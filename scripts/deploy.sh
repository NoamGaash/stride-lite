#!/usr/bin/env bash
# Brings a running node up to a commit. Runs on the instance, sent by SSM from
# .github/workflows/deploy.yml.
#
# infra/bootstrap.sh is user_data, so it runs once per instance launch: it is how
# a node is born, not how it is updated. `user_data_replace_on_change = false` is
# deliberate — a push must not replace the instance, because the 400 GB data
# volume and the hours of backfill on it are the expensive part. So a deploy is
# this script, in place.
set -euxo pipefail

REPO=${REPO:-/opt/stride-lite}
BRANCH=${BRANCH:-main}
export CH_DB=${CH_DB:-stride}
export CH_CLIENT=${CH_CLIENT:-clickhouse client}

cd "$REPO"
# The instance clones --depth 1, so fetch the same way and move to it.
git fetch --depth 1 origin "$BRANCH"
git reset --hard FETCH_HEAD

(cd api && npm ci --omit=dev)

# Tables, then migrations, then views — the order apply-schema.sh enforces, and
# the reason a view may read a column a migration adds in the same deploy.
./scripts/apply-schema.sh
clickhouse client --database "$CH_DB" --multiquery < db/raw.sql
clickhouse client --database "$CH_DB" --multiquery < db/projections.sql
clickhouse client --database "$CH_DB" --multiquery < ingest/siri.sql
clickhouse client --database "$CH_DB" --multiquery < ingest/enrich.sql

systemctl restart stride-api

for _ in $(seq 1 30); do
  curl -fsS http://127.0.0.1/healthz >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS http://127.0.0.1/healthz
echo

# A view whose body changed is replaced, which schedules an immediate refresh.
# Anything that comes back with an exception is a failed deploy, not a warning.
clickhouse client --query "
  SELECT view, status, substring(exception, 1, 200) AS exception
  FROM system.view_refreshes
  WHERE database = '$CH_DB' AND exception != ''
  FORMAT Vertical"
test "$(clickhouse client --query "
  SELECT count() FROM system.view_refreshes
  WHERE database = '$CH_DB' AND exception != ''")" = 0
