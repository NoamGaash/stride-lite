#!/usr/bin/env bash
# Installs the node's ClickHouse config, service units and cron entries from
# infra/node, so they follow the repository the way the code does. Run by
# infra/bootstrap.sh when a node is born and by scripts/deploy.sh on every
# deploy; bootstrap alone is not enough, because it runs once per instance and a
# fix to it never reaches a node that already exists.
#
# Only files that differ are written. With RESTART_CHANGED=1 ClickHouse is
# restarted when its own config or unit changed — never otherwise, since a
# restart interrupts ingestion and any projection still materialising.
# stride-api is the caller's to restart; stride-first-load is never started here.
set -euo pipefail

SRC="$(cd "$(dirname "$0")/../infra/node" && pwd)"
ROOT=${NODE_ROOT:-}
SYSTEMCTL=${SYSTEMCTL:-systemctl}

# Succeeds only when it wrote something.
put() {
  local src=$1 dest=$ROOT$2
  cmp -s "$src" "$dest" && return 1
  install -D -m 0644 "$src" "$dest"
  echo "installed $2"
}

clickhouse_changed=0
units_changed=0

for f in "$SRC"/clickhouse-server/*; do
  put "$f" "/etc/clickhouse-server/$(basename "$f")" && clickhouse_changed=1
done
for f in "$SRC"/systemd/*.service; do
  if put "$f" "/etc/systemd/system/$(basename "$f")"; then
    units_changed=1
    [ "$(basename "$f")" = clickhouse.service ] && clickhouse_changed=1
  fi
done
for f in "$SRC"/cron/*; do
  put "$f" "/etc/cron.d/$(basename "$f")" || true
done

[ "$units_changed" = 0 ] || $SYSTEMCTL daemon-reload
$SYSTEMCTL enable clickhouse stride-api stride-first-load

if [ "$clickhouse_changed" = 1 ] && [ "${RESTART_CHANGED:-0}" = 1 ]; then
  $SYSTEMCTL restart clickhouse
fi
