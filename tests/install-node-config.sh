#!/usr/bin/env bash
# scripts/install-node-config.sh against a scratch root and a recording
# systemctl, starting from a node bootstrapped before stride-api.service set
# CH_URL — the state a deploy could not repair, because only bootstrap wrote
# the unit and bootstrap runs once per instance.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
CALLS=$ROOT/systemctl.calls
cat > "$ROOT/systemctl" <<STUB
#!/bin/sh
echo "\$*" >> "$CALLS"
STUB
chmod +x "$ROOT/systemctl"

fail() { echo "FAIL: $*" >&2; exit 1; }

for f in infra/node/systemd/*.service; do grep -q '^ExecStart=' "$f" || fail "$f has no ExecStart"; done
for f in infra/node/cron/*; do grep -qE '^[@0-9*]' "$f" || fail "$f has no schedule"; done
run() { : > "$CALLS"; NODE_ROOT=$ROOT SYSTEMCTL=$ROOT/systemctl RESTART_CHANGED=1 ./scripts/install-node-config.sh >/dev/null; }

mkdir -p "$ROOT/etc/systemd/system" "$ROOT/etc/clickhouse-server" "$ROOT/etc/cron.d"
cp infra/node/systemd/* "$ROOT/etc/systemd/system/"
cp infra/node/clickhouse-server/* "$ROOT/etc/clickhouse-server/"
cp infra/node/cron/* "$ROOT/etc/cron.d/"
grep -v CH_URL infra/node/systemd/stride-api.service > "$ROOT/etc/systemd/system/stride-api.service"

run
cmp -s infra/node/systemd/stride-api.service "$ROOT/etc/systemd/system/stride-api.service" \
  || fail "the stale stride-api.service was left in place"
grep -qx daemon-reload "$CALLS" || fail "a changed unit was installed without daemon-reload"
grep -q 'restart clickhouse' "$CALLS" && fail "restarted ClickHouse although none of its files changed"

run
grep -qv '^enable ' "$CALLS" && fail "a second run with nothing changed still called: $(cat "$CALLS")"

echo '<!-- edited -->' >> "$ROOT/etc/clickhouse-server/config.xml"
run
cmp -s infra/node/clickhouse-server/config.xml "$ROOT/etc/clickhouse-server/config.xml" \
  || fail "the drifted ClickHouse config was not restored"
grep -qx 'restart clickhouse' "$CALLS" || fail "ClickHouse config changed but ClickHouse was not restarted"

rm "$ROOT/etc/cron.d/stride-gtfs"
run
cmp -s infra/node/cron/stride-gtfs "$ROOT/etc/cron.d/stride-gtfs" || fail "a missing cron entry was not installed"

grep -qE '^cat > /etc/(systemd|cron\.d|clickhouse-server)/' infra/bootstrap.sh \
  && fail "infra/bootstrap.sh still writes node config itself; it belongs in infra/node"
grep -q 'install-node-config.sh' scripts/deploy.sh || fail "scripts/deploy.sh does not install the node config"

echo ok
