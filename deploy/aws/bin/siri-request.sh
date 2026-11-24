#!/usr/bin/env bash
# One SIRI snapshot from the Ministry of Transport: the AllActiveTripsFilter
# answer that Hasadna's requester (github.com/hasadna/open-bus-siri-requester)
# also asks for, brotli-compressed, at
#   s3://$SIRI_BUCKET/siri/YYYY/MM/DD/HH/MM/SS.br
# Run every 15 seconds by deploy/aws/node/systemd/siri-requester.timer. The Ministry
# builds a new answer every 15 seconds and allows a request every 15 seconds
# (ICD SM 2.8, sections 7.15 and 7.18); Hasadna asks once a minute, so its
# archive keeps one answer in four, and its per-minute layout has no room for
# the other three. docs/REQUESTER.md is why a second requester exists.
set -euo pipefail

: "${OPEN_BUS_MOT_KEY:?set the Ministry SIRI key}"
BUCKET=${SIRI_BUCKET:-openbus-mot-archive}
SPOOL=${SIRI_SPOOL:-/var/lib/siri-requester}
now=$(date -u +%s)
ID=${SNAPSHOT_ID:-$(date -u -d "@$((now / 15 * 15))" +%Y/%m/%d/%H/%M/%S)}
# The second host is the Ministry's own fallback, which Hasadna's requester also uses.
HOSTS=(moran.mot.gov.il moran-t.mot.gov.il)

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# The Ministry rebuilds this answer every 15 seconds, so one older than two
# minutes is a server serving a stale copy, not this moment's snapshot.
valid() {
  python3 - "$1" <<'PY'
import datetime, json, sys
d = json.load(open(sys.argv[1]))["Siri"]["ServiceDelivery"]
ts = datetime.datetime.strptime(d["ResponseTimestamp"], "%Y-%m-%dT%H:%M:%S%z")
assert all(isinstance(s["MonitoredStopVisit"], list) for s in d["StopMonitoringDelivery"])
age = (datetime.datetime.now(datetime.timezone.utc) - ts).total_seconds()
sys.exit(0 if age <= 120 else 1)
PY
}

# The key goes in on stdin, so it is never in a process's command line.
ask() {
  curl -sS --fail --max-time 6 -o "$work/answer.json" --config - <<EOF
url = "https://$1/Channels/HTTPChannel/SmQuery/2.8/json"
get
data-urlencode = "Key=$OPEN_BUS_MOT_KEY"
data = "MonitoringRef=AllActiveTripsFilter"
data = "StopVisitDetailLevel=normal"
EOF
}

# No second round: the next run is 15 seconds away and asks again anyway.
fetch() {
  for host in "${HOSTS[@]}"; do
    if ask "$host" && valid "$work/answer.json" 2>/dev/null; then
      echo "snapshot $ID from $host"
      return 0
    fi
    echo "no current snapshot from $host"
  done
  return 1
}

# Every snapshot not yet in S3, this minute's and any an outage left behind;
# each is deleted once it is there.
upload() {
  local failed=0 f
  while IFS= read -r f; do
    if aws s3 cp "$f" "s3://$BUCKET/siri/${f#"$SPOOL"/}" --only-show-errors; then
      rm -f "$f"
    else
      failed=1
    fi
  done < <(find "$SPOOL" -name '*.br' | sort)
  find "$SPOOL" -mindepth 1 -type d -empty -delete
  return "$failed"
}

mkdir -p "$SPOOL"
# Two days of an S3 outage is about 1 GB, on the disk ClickHouse needs.
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
