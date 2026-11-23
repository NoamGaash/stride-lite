#!/usr/bin/env bash
# scripts/naim-rt-request.sh with curl and aws replaced by stubs on PATH. The
# feed is a file; the bucket is a directory.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR=$(mktemp -d); trap 'rm -rf "$DIR"' EXIT
mkdir -p "$DIR/bin" "$DIR/s3" "$DIR/spool"

# curl ... -o FILE URL: copies $DIR/feed.pb, or fails while it is missing.
cat > "$DIR/bin/curl" <<STUB
#!/bin/sh
prev=; for a; do [ "\$prev" = -o ] && out=\$a; prev=\$a; done
[ -f "$DIR/feed.pb" ] || exit 22
cp "$DIR/feed.pb" "\$out"
STUB
# aws s3 mv SPOOL s3://openbus-mot-archive/naim/gtfs-rt/ --recursive ...;
# fails while $DIR/s3.down exists, and then leaves the spool as it was.
cat > "$DIR/bin/aws" <<STUB
#!/bin/sh
[ -e "$DIR/s3.down" ] && exit 1
dest="$DIR/s3/\${4#s3://openbus-mot-archive/}"
(cd "\$3" && find . -name '*.pb') | while read -r f; do
  mkdir -p "\$(dirname "\$dest/\$f")"; mv "\$3/\$f" "\$dest/\$f"
done
STUB
chmod +x "$DIR"/bin/*

fail() { echo "FAIL: $*" >&2; exit 1; }
run() { PATH=$DIR/bin:$PATH NAIM_RT_SPOOL=$DIR/spool SNAPSHOT_ID=$1 ./scripts/naim-rt-request.sh >/dev/null 2>&1; }
stored() { [ -f "$DIR/s3/naim/gtfs-rt/$1.pb" ]; }
# Field 1, a 13-byte header, as the live feed sent on a Monday with no service.
header='\012\015\012\0032.0\020\000\030\200\200\200\200\001'
# Field 2, one entity of 4 bytes.
entity='\022\004\012\002v1'

printf "$header" > "$DIR/feed.pb"
run 2026/11/23/12/00/00 || fail "a feed with no vehicles failed"
[ -z "$(find "$DIR/s3" "$DIR/spool" -type f)" ] || fail "a feed with no vehicles was kept"

printf "$header$entity" > "$DIR/feed.pb"
run 2026/11/27/14/00/10 || fail "a feed with vehicles failed"
stored 2026/11/27/14/00/10 || fail "a feed with vehicles was not stored"
cmp -s "$DIR/feed.pb" "$DIR/s3/naim/gtfs-rt/2026/11/27/14/00/10.pb" || fail "the stored snapshot is not the feed"

touch "$DIR/s3.down"
run 2026/11/27/14/00/20 && fail "a failed upload was reported as success"
rm "$DIR/s3.down"
run 2026/11/27/14/00/30 || fail "the run after an S3 outage failed"
stored 2026/11/27/14/00/20 || fail "a snapshot taken during an S3 outage was not uploaded later"
stored 2026/11/27/14/00/30 || fail "the snapshot after an outage was not stored"
[ -z "$(find "$DIR/spool" -type f)" ] || fail "an uploaded snapshot was left on the node's disk"

echo "naim-rt-request: ok"
