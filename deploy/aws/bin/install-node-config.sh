#!/usr/bin/env bash
# Installs the node's ClickHouse config, service units and cron entries from
# deploy/aws/node, so they follow the repository the way the code does. Run by
# deploy/aws/bootstrap.sh when a node is born and by deploy/aws/bin/deploy.sh on every
# deploy; bootstrap alone is not enough, because it runs once per instance and a
# fix to it never reaches a node that already exists.
#
# Only files that differ are written, and a unit of ours that deploy/aws/node no
# longer has is disabled and removed. With RESTART_CHANGED=1 ClickHouse is
# restarted when its own config or unit changed — never otherwise, since a
# restart interrupts ingestion and any projection still materialising.
# stride-api is the caller's to restart; stride-first-load is never started here.
set -euo pipefail

SRC="$(cd "$(dirname "$0")/../node" && pwd)"
ROOT=${NODE_ROOT:-}
SYSTEMCTL=${SYSTEMCTL:-systemctl}

# Succeeds only when it wrote something.
put() {
  local src=$1 dest=$ROOT$2
  cmp -s "$src" "$dest" && return 1
  install -D -m 0644 "$src" "$dest"
  echo "installed $2"
}

# The API's image first: the unit installed below runs it. Tests skip this.
[ "${PULL_IMAGE:-1}" = 0 ] || "$(dirname "$0")/pull-image.sh"

clickhouse_changed=0
units_changed=0

for f in "$SRC"/clickhouse-server/*; do
  put "$f" "/etc/clickhouse-server/$(basename "$f")" && clickhouse_changed=1
done
for f in "$SRC"/systemd/*.service "$SRC"/systemd/*.timer; do
  if put "$f" "/etc/systemd/system/$(basename "$f")"; then
    units_changed=1
    [ "$(basename "$f")" = clickhouse.service ] && clickhouse_changed=1
  fi
done
# Ours means it runs something from /opt/stride-lite, or is the timer of a
# service that does. A service is only disabled, not stopped: the run in
# progress may be the one that removed it.
stale=()
for f in "$ROOT"/etc/systemd/system/*.service "$ROOT"/etc/systemd/system/*.timer; do
  [ -e "$f" ] && [ ! -e "$SRC/systemd/$(basename "$f")" ] || continue
  grep -qs /opt/stride-lite "$f" "${f%.*}.service" && stale+=("$f")
done
for f in "${stale[@]}"; do
  case $f in *.timer) $SYSTEMCTL disable --now "$(basename "$f")" ;; *) $SYSTEMCTL disable "$(basename "$f")" ;; esac
  rm "$f"
  echo "removed ${f#"$ROOT"}"
  units_changed=1
done
for f in "$SRC"/cron/*; do
  put "$f" "/etc/cron.d/$(basename "$f")" || true
done

[ "$units_changed" = 0 ] || $SYSTEMCTL daemon-reload
$SYSTEMCTL enable clickhouse stride-api stride-first-load
$SYSTEMCTL enable --now swapfile.service
# Every 15 seconds, once there is a Ministry key to ask with.
if grep -qs '^OPEN_BUS_MOT_KEY=.' "$ROOT/etc/stride-lite/node.env"; then
  $SYSTEMCTL enable --now siri-requester.timer
else
  $SYSTEMCTL disable --now siri-requester.timer
fi
$SYSTEMCTL enable --now gtfs-archive.timer
$SYSTEMCTL enable --now naim-rt-request.timer

if [ "$clickhouse_changed" = 1 ] && [ "${RESTART_CHANGED:-0}" = 1 ]; then
  $SYSTEMCTL restart clickhouse
fi
