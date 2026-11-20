#!/usr/bin/env bash
# Every minute, from infra/node/systemd/siri-requester-watchdog.timer. systemd
# restarts the requester when it exits; this restarts it when it hangs, which
# the daemon's own status file shows: it is rewritten after every snapshot.
# Four minutes is the threshold Hasadna's health check for the same daemon uses.
set -euo pipefail

ROOT=${OPEN_BUS_SIRI_STORAGE_ROOTPATH:?}
SYSTEMCTL=${SYSTEMCTL:-systemctl}
MAX_SILENT_SECONDS=${MAX_SILENT_SECONDS:-240}
KEEP_MINUTES=${KEEP_MINUTES:-2880}

# Each snapshot is uploaded as soon as it is written, so the local copy is kept
# only to retry from, and the disk it would fill is ClickHouse's.
if [ -d "$ROOT" ]; then
  find "$ROOT" -name '*.br' -mmin +"$KEEP_MINUTES" -delete
  find "$ROOT" -mindepth 1 -type d -empty -delete
fi

[ -n "${OPEN_BUS_MOT_KEY:-}" ] || exit 0

if ! $SYSTEMCTL is-active --quiet siri-requester; then
  echo "siri-requester is not running; starting it"
  exec $SYSTEMCTL start siri-requester
fi

now=$(date +%s)
since=$(date -d "$($SYSTEMCTL show siri-requester -p ActiveEnterTimestamp --value)" +%s)
[ $((now - since)) -gt "$MAX_SILENT_SECONDS" ] || exit 0

last=$(stat -c %Y "$ROOT/daemon_status.json" 2>/dev/null || echo 0)
if [ $((now - last)) -gt "$MAX_SILENT_SECONDS" ]; then
  echo "no snapshot for $(( (now - last) / 60 )) minutes; restarting siri-requester"
  $SYSTEMCTL restart siri-requester
fi
