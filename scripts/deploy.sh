#!/usr/bin/env bash
# Brings a running node up to a commit. Runs on the instance, sent by SSM from
# .github/workflows/deploy.yml.
#
# infra/bootstrap.sh is user_data, so it runs once per instance launch: it is how
# a node is born, not how it is updated. `user_data_replace_on_change = false` is
# deliberate — a push must not replace the instance, because the 350 GB data
# volume and the hours of first load on it are the expensive part. So a deploy is
# this script, in place.
set -euxo pipefail

REPO=${REPO:-/opt/stride-lite}
BRANCH=${BRANCH:-main}
LOCK=${FIRST_LOAD_LOCK:-/var/lock/stride-catchup}
export CH_DB=${CH_DB:-stride}
export CH_CLIENT=${CH_CLIENT:-clickhouse client}

cd "$REPO"
# The instance clones --depth 1, so fetch the same way and move to it.
git fetch --depth 1 origin "$BRANCH"
git reset --hard FETCH_HEAD

(cd api && npm ci --omit=dev)

# Everything past this point writes to the database, and scripts/first-load.sh
# and ingest/catchup.sh take this same lock. Ten minutes is long enough for a
# catch-up tick to finish and far short of a first load, which is measured in
# hours — so a deploy during a first load updates the code and leaves the schema
# alone rather than becoming a second writer. Two writers is not a slow deploy,
# it is duplicated ids: both the dump's own and the enrichment's are minted from
# max(id), and that failure cost this project twenty-nine days of data.
#
# Skipping is deliberate and bounded: the next deploy converges the schema, and
# the first load's own `live` stage installs the ingest chain this would have.
if flock -w 600 9; then
  # Tables, then migrations, then views, then projections — the order
  # apply-schema.sh enforces, and the reason a view may read a column a
  # migration adds in the same deploy.
  ./scripts/apply-schema.sh
  # Only once the first load has installed them. Applying ingest/siri.sql to a
  # node still loading history would start the live chain alongside the load.
  if [ "$(clickhouse client --database "$CH_DB" --query "
            SELECT count() FROM system.view_refreshes
            WHERE database = '$CH_DB' AND startsWith(view, 'enrich_')")" != 0 ]; then
    clickhouse client --database "$CH_DB" --multiquery < ingest/siri.sql
    clickhouse client --database "$CH_DB" --multiquery < ingest/enrich.sql
    clickhouse client --database "$CH_DB" --multiquery < ingest/health.sql
  else
    echo "the enrichment chain is not installed yet; first-load.sh owns that"
  fi
else
  echo "another ingest run holds $LOCK after ten minutes of waiting:"
  echo "updating the code only, and leaving the schema to the next deploy."
  systemctl status stride-first-load --no-pager || true
fi 9> "$LOCK"

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
