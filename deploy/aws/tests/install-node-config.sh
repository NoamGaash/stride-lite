#!/usr/bin/env bash
# deploy/aws/bin/install-node-config.sh against a scratch root and a recording
# systemctl, starting from a node bootstrapped before stride-api.service set
# CH_URL — the state a deploy could not repair, because only bootstrap wrote
# the unit and bootstrap runs once per instance.
set -euo pipefail
cd "$(dirname "$0")/../../.."
ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
CALLS=$ROOT/systemctl.calls
cat > "$ROOT/systemctl" <<STUB
#!/bin/sh
echo "\$*" >> "$CALLS"
STUB
chmod +x "$ROOT/systemctl"

fail() { echo "FAIL: $*" >&2; exit 1; }

for f in deploy/aws/node/systemd/*.service; do grep -q '^ExecStart=' "$f" || fail "$f has no ExecStart"; done

# The status page serves these logs, and a line with no time on it cannot say
# whether it is from this hour or from last week.
for f in deploy/aws/node/cron/*; do
  grep -E '^[@0-9*].*/var/log/' "$f" | grep -qv stamp-lines && fail "$f logs without timestamps"
done
grep -q '^ExecStart=.*stamp-lines' deploy/aws/node/systemd/stride-first-load.service \
  || fail "the first load logs without timestamps"
got=$(printf 'one\ntwo' | deploy/aws/bin/stamp-lines.sh)
echo "$got" | grep -qxE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z two' \
  || fail "stamp-lines dropped or did not stamp an unterminated last line: '$got'"
for f in deploy/aws/node/cron/*; do grep -qE '^[@0-9*]' "$f" || fail "$f has no schedule"; done
# cron runs its commands with PATH=/usr/bin:/bin, and the ClickHouse client
# lives wherever clickhouse.service starts the server from.
ch_dir=$(dirname "$(sed -n 's/^ExecStart=\([^ ]*\).*/\1/p' deploy/aws/node/systemd/clickhouse.service)")
for f in deploy/aws/node/cron/*; do
  path=$(sed -n 's/^PATH=//p' "$f")
  case ":$path:" in *":$ch_dir:"*) ;; *) fail "$f runs \`clickhouse\` without $ch_dir on its PATH ('${path:-cron default}')" ;; esac
done
run() { : > "$CALLS"; PULL_IMAGE=0 NODE_ROOT=$ROOT SYSTEMCTL=$ROOT/systemctl RESTART_CHANGED=1 ./deploy/aws/bin/install-node-config.sh >/dev/null; }

mkdir -p "$ROOT/etc/systemd/system" "$ROOT/etc/clickhouse-server" "$ROOT/etc/cron.d"
cp deploy/aws/node/systemd/* "$ROOT/etc/systemd/system/"
cp deploy/aws/node/clickhouse-server/* "$ROOT/etc/clickhouse-server/"
cp deploy/aws/node/cron/* "$ROOT/etc/cron.d/"
grep -v CH_URL deploy/aws/node/systemd/stride-api.service > "$ROOT/etc/systemd/system/stride-api.service"
# A unit of ours the repository no longer has, with its timer, and one that is
# not ours at all.
printf '[Service]\nExecStart=/opt/stride-lite/gone.sh\n' > "$ROOT/etc/systemd/system/stride-gone.service"
printf '[Timer]\nOnUnitInactiveSec=5min\n' > "$ROOT/etc/systemd/system/stride-gone.timer"
printf '[Service]\nExecStart=/usr/bin/true\n' > "$ROOT/etc/systemd/system/someone-else.service"

run
cmp -s deploy/aws/node/systemd/stride-api.service "$ROOT/etc/systemd/system/stride-api.service" \
  || fail "the stale stride-api.service was left in place"
grep -qx daemon-reload "$CALLS" || fail "a changed unit was installed without daemon-reload"
[ -e "$ROOT/etc/systemd/system/stride-gone.service" ] && fail "a unit the repository dropped was left installed"
[ -e "$ROOT/etc/systemd/system/stride-gone.timer" ] && fail "the timer of a dropped unit was left installed"
grep -qx 'disable --now stride-gone.timer' "$CALLS" || fail "the dropped timer was not stopped"
grep -qx 'disable stride-gone.service' "$CALLS" || fail "the dropped service was not disabled, or was stopped"
[ -e "$ROOT/etc/systemd/system/someone-else.service" ] || fail "removed a unit that is not ours"
grep -qx 'disable --now siri-requester.timer' "$CALLS" || fail "the requester timer runs with no key to ask with"
grep -qx 'enable --now gtfs-archive.timer' "$CALLS" || fail "the GTFS archive timer was not started"
grep -qx 'enable --now swapfile.service' "$CALLS" || fail "the swap file was not turned on"
grep -q 'restart clickhouse' "$CALLS" && fail "restarted ClickHouse although none of its files changed"

run
grep -qvE '^(enable|disable) ' "$CALLS" && fail "a second run with nothing changed still called: $(cat "$CALLS")"

mkdir -p "$ROOT/etc/stride-lite"
echo 'OPEN_BUS_MOT_KEY=k' > "$ROOT/etc/stride-lite/node.env"
run
grep -qx 'enable --now siri-requester.timer' "$CALLS" || fail "the requester timer was not started once the key was there"

echo '<!-- edited -->' >> "$ROOT/etc/clickhouse-server/config.xml"
run
cmp -s deploy/aws/node/clickhouse-server/config.xml "$ROOT/etc/clickhouse-server/config.xml" \
  || fail "the drifted ClickHouse config was not restored"
grep -qx 'restart clickhouse' "$CALLS" || fail "ClickHouse config changed but ClickHouse was not restarted"

rm "$ROOT/etc/cron.d/stride-gtfs"
run
cmp -s deploy/aws/node/cron/stride-gtfs "$ROOT/etc/cron.d/stride-gtfs" || fail "a missing cron entry was not installed"

grep -qE '^cat > /etc/(systemd|cron\.d|clickhouse-server)/' deploy/aws/bootstrap.sh deploy/aws/bin/bootstrap-node.sh \
  && fail "the bootstrap still writes node config itself; it belongs in deploy/aws/node"
grep -q 'install-node-config.sh' deploy/aws/bin/deploy.sh || fail "deploy/aws/bin/deploy.sh does not install the node config"

echo ok
