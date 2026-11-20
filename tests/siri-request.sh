#!/usr/bin/env bash
# scripts/siri-request.sh with curl, brotli and aws replaced by stubs on PATH:
# curl answers from per-host fixture files, aws copies into a directory.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR=$(mktemp -d); trap 'rm -rf "$DIR"' EXIT
mkdir -p "$DIR/bin" "$DIR/mot" "$DIR/s3" "$DIR/spool"

# curl -o FILE --config -: the url line on stdin picks $DIR/mot/<host>, and no
# such file means no answer. The key must arrive there, never as an argument.
cat > "$DIR/bin/curl" <<STUB
#!/bin/sh
out=; for a; do [ "\$prev" = -o ] && out=\$a; prev=\$a; done
echo "\$*" | grep -q 'secret-key' && { echo "the key is on the command line" >&2; exit 99; }
cfg=\$(cat)
echo "\$cfg" | grep -q 'Key=secret-key' || exit 98
host=\$(echo "\$cfg" | sed -n 's#^url = "https://\([^/]*\)/.*#\1#p')
echo "\$host" >> "$DIR/curl.calls"
[ -f "$DIR/mot/\$host" ] || exit 7
cp "$DIR/mot/\$host" "\$out"
STUB
printf '#!/bin/sh\ncat\n' > "$DIR/bin/brotli"
# aws s3 cp SRC s3://bucket/KEY; fails while $DIR/s3.down exists.
cat > "$DIR/bin/aws" <<STUB
#!/bin/sh
[ -e "$DIR/s3.down" ] && exit 1
dest="$DIR/s3/\${4#s3://}"; mkdir -p "\$(dirname "\$dest")"; cp "\$3" "\$dest"
STUB
chmod +x "$DIR"/bin/*

fail() { echo "FAIL: $*" >&2; exit 1; }
snapshot() { # a response the Ministry generated $1 seconds ago
  printf '{"Siri":{"ServiceDelivery":{"ResponseTimestamp":"%s","StopMonitoringDelivery":[{"MonitoredStopVisit":[{"RecordedAtTime":"%s"}]}]}}}' \
    "$(date -u -d "-$1 sec" +%Y-%m-%dT%H:%M:%S+00:00)" "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)"
}
run() {
  : > "$DIR/curl.calls"
  PATH=$DIR/bin:$PATH OPEN_BUS_MOT_KEY=secret-key SIRI_BUCKET=b SIRI_SPOOL=$DIR/spool SIRI_RETRY_WAIT=0 \
    SNAPSHOT_ID=$1 ./scripts/siri-request.sh >/dev/null 2>&1
}
stored() { [ -f "$DIR/s3/b/stride-siri-requester/$1.br" ]; }

snapshot 5 > "$DIR/mot/moran.mot.gov.il"
run 2026/11/21/10/00 || fail "a good answer from the main server failed"
stored 2026/11/21/10/00 || fail "a good answer was not uploaded under its minute"
grep -q '"MonitoredStopVisit"' "$DIR/s3/b/stride-siri-requester/2026/11/21/10/00.br" || fail "the stored snapshot is not the answer"
[ -z "$(ls -A "$DIR/spool")" ] || fail "a snapshot that reached S3 was kept locally"

rm "$DIR/mot/moran.mot.gov.il"; snapshot 5 > "$DIR/mot/moran-t.mot.gov.il"
run 2026/11/21/10/01 || fail "the fallback server's answer was not used"
stored 2026/11/21/10/01 || fail "the fallback's answer was not uploaded"

# An answer is the Ministry's newest only if it is recent; an old one is not this minute.
snapshot 600 > "$DIR/mot/moran.mot.gov.il"; snapshot 600 > "$DIR/mot/moran-t.mot.gov.il"
run 2026/11/21/10/02 && fail "a ten-minute-old answer was accepted"
stored 2026/11/21/10/02 && fail "a ten-minute-old answer was uploaded"
[ "$(grep -c . "$DIR/curl.calls")" -gt 2 ] || fail "after both servers failed it did not try again"

echo 'not json' > "$DIR/mot/moran.mot.gov.il"; rm "$DIR/mot/moran-t.mot.gov.il"
run 2026/11/21/10/03 && fail "an answer that is not SIRI was accepted"

snapshot 5 > "$DIR/mot/moran.mot.gov.il"; touch "$DIR/s3.down"
run 2026/11/21/10/04 && fail "a failed upload was reported as success"
[ -f "$DIR/spool/2026/11/21/10/04.br" ] || fail "a snapshot that did not reach S3 was not kept to retry"
rm "$DIR/s3.down"
run 2026/11/21/10/05 || fail "the run after an S3 outage failed"
stored 2026/11/21/10/04 || fail "the snapshot kept during the outage was not uploaded later"
stored 2026/11/21/10/05 || fail "the snapshot after the outage was not uploaded"
[ -z "$(find "$DIR/spool" -name '*.br')" ] || fail "uploaded snapshots were left in the spool"

# A spool S3 never accepts must not fill ClickHouse's disk.
mkdir -p "$DIR/spool/2026/11/18/10"; touch -d '-3 days' "$DIR/spool/2026/11/18/10/00.br"; touch "$DIR/s3.down"
run 2026/11/21/10/06 || true
[ -e "$DIR/spool/2026/11/18" ] && fail "a three-day-old unsent snapshot was kept"

echo "siri-request: ok"
