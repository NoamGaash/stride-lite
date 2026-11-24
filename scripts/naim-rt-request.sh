#!/usr/bin/env bash
# One GTFS-RT vehicle-positions snapshot of Tel Aviv-Yafo's weekend lines,
# "Naim BaSofash", at
#   s3://$ARCHIVE_BUCKET/naim/gtfs-rt/YYYY/MM/DD/HH/MM/SS.pb
# Run every 10 seconds by deploy/aws/node/systemd/naim-rt-request.timer; the feed
# updates every 10 seconds, only while the service runs (Friday and Saturday).
# Its trip_id and stop_id refer to the city's own GTFS, which
# scripts/gtfs-archive.sh keeps under naim/gtfs/ (#74). No key, no allowlist.
#
# Outside service hours the feed is a header with no vehicles; that is not
# kept, so most of the week this costs one small curl and nothing else.
set -euo pipefail

URL=${NAIM_RT_URL:-https://api.goryde.com/api/v1/core/c/101/gtfs-rt/vehicle-positions}
BUCKET=${ARCHIVE_BUCKET:?set ARCHIVE_BUCKET to the bucket that keeps the feeds}
SPOOL=${NAIM_RT_SPOOL:-/var/lib/naim-rt-request}
now=$(date -u +%s)
ID=${SNAPSHOT_ID:-$(date -u -d "@$((now / 10 * 10))" +%Y/%m/%d/%H/%M/%S)}

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# A FeedMessage is field 1, the header, then field 2 once per vehicle. This
# reads only the top-level tags, so it needs no protobuf library.
has_vehicles() {
  python3 - "$1" <<'PY'
import sys
b = open(sys.argv[1], "rb").read()
def varint(i):
    n = s = 0
    while True:
        c = b[i]; i += 1; n |= (c & 0x7F) << s; s += 7
        if c < 0x80: return n, i
i = 0
while i < len(b):
    tag, i = varint(i)
    if tag & 7 != 2: sys.exit(2)          # a FeedMessage has only length-delimited fields
    if tag >> 3 == 2: sys.exit(0)
    n, i = varint(i); i += n
sys.exit(1)
PY
}

mkdir -p "$SPOOL"
# Two days of an S3 outage during service is about 17,000 small files.
find "$SPOOL" -name '*.pb' -mmin +2880 -delete

curl -sS --fail --max-time 8 -o "$work/feed.pb" "$URL"
if has_vehicles "$work/feed.pb"; then
  mkdir -p "$SPOOL/$(dirname "$ID")"
  mv "$work/feed.pb" "$SPOOL/$ID.pb"
  echo "snapshot $ID"
fi

# Whatever is waiting, this snapshot and any an outage left behind; a file is
# deleted here only once it is in S3.
if [ -n "$(find "$SPOOL" -name '*.pb' -print -quit)" ]; then
  aws s3 mv "$SPOOL" "s3://$BUCKET/naim/gtfs-rt/" --recursive --exclude '*' --include '*.pb' --only-show-errors
fi
find "$SPOOL" -mindepth 1 -type d -empty -delete
