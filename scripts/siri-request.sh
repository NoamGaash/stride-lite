#!/usr/bin/env bash
# One SIRI snapshot from the Ministry of Transport, stored the way Hasadna's
# requester (github.com/hasadna/open-bus-siri-requester) stores it: the
# AllActiveTripsFilter answer, brotli-compressed, at
#   s3://$SIRI_BUCKET/stride-siri-requester/YYYY/MM/DD/HH/MM.br
# for the minute it was asked for, so the ingest reads it like Hasadna's archive.
# Run every minute by infra/node/systemd/siri-requester.timer; docs/REQUESTER.md
# is why a second requester exists.
set -euo pipefail

: "${OPEN_BUS_MOT_KEY:?set the Ministry SIRI key}"
BUCKET=${SIRI_BUCKET:-openbus-siri-snapshots}
SPOOL=${SIRI_SPOOL:-/var/lib/siri-requester}
RETRY_WAIT=${SIRI_RETRY_WAIT:-15}
ID=${SNAPSHOT_ID:-$(date -u +%Y/%m/%d/%H/%M)}
# The second host is the Ministry's own fallback, which Hasadna's requester also uses.
HOSTS=(moran.mot.gov.il moran-t.mot.gov.il)

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# The Ministry rebuilds this answer every 15 seconds, so one older than six
# minutes is a server serving a stale copy, not this minute's snapshot.
valid() {
  python3 - "$1" <<'PY'
import datetime, json, sys
d = json.load(open(sys.argv[1]))["Siri"]["ServiceDelivery"]
ts = datetime.datetime.strptime(d["ResponseTimestamp"], "%Y-%m-%dT%H:%M:%S%z")
assert all(isinstance(s["MonitoredStopVisit"], list) for s in d["StopMonitoringDelivery"])
age = (datetime.datetime.now(datetime.timezone.utc) - ts).total_seconds()
sys.exit(0 if age <= 360 else 1)
PY
}

# The key goes in on stdin, so it is never in a process's command line.
ask() {
  curl -sS --fail --max-time 12 -o "$work/answer.json" --config - <<EOF
url = "https://$1/Channels/HTTPChannel/SmQuery/2.8/json"
get
data-urlencode = "Key=$OPEN_BUS_MOT_KEY"
data = "MonitoringRef=AllActiveTripsFilter"
data = "StopVisitDetailLevel=normal"
EOF
}

fetch() {
  for round in 1 2; do
    for host in "${HOSTS[@]}"; do
      if ask "$host" && valid "$work/answer.json" 2>/dev/null; then
        echo "snapshot $ID from $host"
        return 0
      fi
      echo "no current snapshot from $host"
    done
    [ "$round" = 2 ] || sleep "$RETRY_WAIT"
  done
  return 1
}

# Every snapshot not yet in S3, this minute's and any an outage left behind;
# each is deleted once it is there.
upload() {
  local failed=0 f
  while IFS= read -r f; do
    if aws s3 cp "$f" "s3://$BUCKET/stride-siri-requester/${f#"$SPOOL"/}" --only-show-errors; then
      rm -f "$f"
    else
      failed=1
    fi
  done < <(find "$SPOOL" -name '*.br' | sort)
  find "$SPOOL" -mindepth 1 -type d -empty -delete
  return "$failed"
}

mkdir -p "$SPOOL"
# Two days of an S3 outage is about 3 GB, on the disk ClickHouse needs.
find "$SPOOL" -name '*.br' -mmin +2880 -delete
find "$SPOOL" -mindepth 1 -type d -empty -delete

fetched=0
if fetch; then
  mkdir -p "$SPOOL/$(dirname "$ID")"
  brotli -c < "$work/answer.json" > "$work/answer.br"
  mv "$work/answer.br" "$SPOOL/$ID.br"
  fetched=1
fi
upload || { echo "S3 refused an upload; kept for the next run"; exit 1; }
[ "$fetched" = 1 ]
