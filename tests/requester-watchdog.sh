#!/usr/bin/env bash
# scripts/requester-watchdog.sh against a scratch storage directory and a
# recording systemctl that reports whatever state each case sets.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR=$(mktemp -d); trap 'rm -rf "$DIR"' EXIT
CALLS=$DIR/calls
cat > "$DIR/systemctl" <<STUB
#!/bin/sh
echo "\$*" >> "$CALLS"
case "\$*" in
  "is-active --quiet siri-requester") [ "\$STUB_ACTIVE" = 1 ] ;;
  "show siri-requester -p ActiveEnterTimestamp --value") echo "\$STUB_SINCE" ;;
esac
STUB
chmod +x "$DIR/systemctl"

fail() { echo "FAIL: $*" >&2; exit 1; }
ago() { date -d "-$1 min" '+%a %Y-%m-%d %H:%M:%S %Z'; }
run() {
  : > "$CALLS"
  OPEN_BUS_SIRI_STORAGE_ROOTPATH=$DIR/siri SYSTEMCTL=$DIR/systemctl ./scripts/requester-watchdog.sh >/dev/null
}
status_written() { touch -d "-$1 min" "$DIR/siri/daemon_status.json"; }
restarted() { grep -qx 'restart siri-requester' "$CALLS"; }

mkdir -p "$DIR/siri/2026/11/17/08" "$DIR/siri/2026/11/20/21"
touch -d '-3 days' "$DIR/siri/2026/11/17/08/00.br"
touch -d '-5 min' "$DIR/siri/2026/11/20/21/04.br"

# The snapshots are in S3 the moment they are written; two days of them is
# about 3 GB the node keeps only for a retry, and the disk is ClickHouse's.
unset OPEN_BUS_MOT_KEY
run
[ -e "$DIR/siri/2026/11/17" ] && fail "a three-day-old snapshot, or its emptied directories, was kept"
[ -e "$DIR/siri/2026/11/20/21/04.br" ] || fail "a recent snapshot was deleted"
[ -s "$CALLS" ] && fail "with no Ministry key it still touched the requester: $(cat "$CALLS")"

export OPEN_BUS_MOT_KEY=k
STUB_ACTIVE=0 STUB_SINCE='' run
grep -qx 'start siri-requester' "$CALLS" || fail "a stopped requester was not started"

export STUB_ACTIVE=1
STUB_SINCE=$(ago 10) status_written 1; STUB_SINCE=$(ago 10) run
restarted && fail "restarted a requester that wrote a minute ago"

STUB_SINCE=$(ago 10) status_written 10; STUB_SINCE=$(ago 10) run
restarted || fail "a requester silent for ten minutes was not restarted"

# Just restarted: its last snapshot is old because it has not had a minute yet.
status_written 10; STUB_SINCE=$(ago 1) run
restarted && fail "restarted a requester that started a minute ago"

rm "$DIR/siri/daemon_status.json"; STUB_SINCE=$(ago 10) run
restarted || fail "a requester that never wrote a snapshot in ten minutes was not restarted"

echo "requester-watchdog: ok"
