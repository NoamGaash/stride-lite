#!/usr/bin/env bash
# scripts/gtfs-archive.sh with curl and aws replaced by stubs on PATH. The
# Ministry is a directory of files with their Last-Modified times; the archive
# bucket is another directory, readable over "https" the way the public one is.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR=$(mktemp -d); trap 'rm -rf "$DIR"' EXIT
mkdir -p "$DIR/bin" "$DIR/mot" "$DIR/naim" "$DIR/s3" "$DIR/work"
FILES=(israel-public-transportation.zip Gtfs_10_days.zip RouteNetworksByDate_10_Days.zip)

# curl [-I] [-o FILE] URL. gtfs.mot.gov.il serves $DIR/mot; the archive bucket
# serves $DIR/s3. A HEAD prints Last-Modified from the file's mtime.
cat > "$DIR/bin/curl" <<STUB
#!/bin/sh
head=0; out=; prev=
for a; do
  [ "\$prev" = -o ] && out=\$a
  case \$a in -I|-sSfI|-sfI) head=1 ;; https://*) url=\$a ;; esac
  prev=\$a
done
case \$url in
  https://gtfs.mot.gov.il/gtfsfiles/*) f="$DIR/mot/\${url##*/}" ;;
  https://opendatasource.tel-aviv.gov.il/OpenData_Ducaments/*) f="$DIR/naim/\${url##*/}" ;;
  https://openbus-mot-archive.s3.amazonaws.com/*) f="$DIR/s3/\${url#https://openbus-mot-archive.s3.amazonaws.com/}" ;;
  *) exit 6 ;;
esac
[ -f "\$f" ] || exit 22
echo "\$head \$url" >> "$DIR/curl.calls"
if [ \$head = 1 ]; then
  echo "HTTP/1.1 200 OK"; echo "Last-Modified: \$(date -u -r "\$f" '+%a, %d %b %Y %H:%M:%S GMT')"
else
  cp "\$f" "\$out"
fi
STUB
# aws s3 cp SRC s3://openbus-mot-archive/KEY; fails while $DIR/s3.down exists.
cat > "$DIR/bin/aws" <<STUB
#!/bin/sh
[ -e "$DIR/s3.down" ] && exit 1
dest="$DIR/s3/\${4#s3://openbus-mot-archive/}"; mkdir -p "\$(dirname "\$dest")"; cp "\$3" "\$dest"
STUB
chmod +x "$DIR"/bin/*

fail() { echo "FAIL: $*" >&2; exit 1; }
publish() { # the Ministry publishes $1 with Last-Modified $2
  echo "$1 at $2" > "$DIR/mot/$1"; touch -d "$2" "$DIR/mot/$1"
}
run() {
  : > "$DIR/curl.calls"
  PATH=$DIR/bin:$PATH GTFS_WORKDIR=$DIR/work ./scripts/gtfs-archive.sh >/dev/null 2>&1
}
archived() { [ -f "$DIR/s3/gtfs/$1/$2" ]; }
# Where a file published at $2 is expected: Hasadna's layout for the current
# format, the day and time for the 10-day one.
at() { if [ "$1" = israel-public-transportation.zip ]; then date -u -d "$2" +%Y/%m/%d; else date -u -d "$2" +%Y/%m/%d/%H%M%S; fi; }
downloads() { grep -c '^0 https://gtfs.mot.gov.il' "$DIR/curl.calls" || true; }

for f in "${FILES[@]}"; do publish "$f" '2026-11-20 01:47:53 UTC'; done
echo "naim at 1" > "$DIR/naim/gtfs.zip"; touch -d '2026-11-20 23:00:17 UTC' "$DIR/naim/gtfs.zip"
run || fail "archiving three published files failed"
for f in "${FILES[@]}"; do
  archived "$(at "$f" '2026-11-20 01:47:53 UTC')" "$f" || fail "$f was not archived under the time the Ministry published it"
done
grep -q "Gtfs_10_days.zip at" "$DIR/s3/gtfs/2026/11/20/014753/Gtfs_10_days.zip" || fail "the archived file is not the Ministry's"
[ -z "$(ls -A "$DIR/work")" ] || fail "a downloaded file was left on the node's disk"

# Tel Aviv's weekend lines, from the city's portal, under a prefix of their own;
# their twice-daily updates are each kept.
[ -f "$DIR/s3/naim/gtfs/2026/11/20/230017/gtfs.zip" ] || fail "Naim BaSofash's GTFS was not archived"

# Every few hours it looks again; a day already archived is not downloaded twice.
run || fail "a run with nothing new failed"
[ "$(downloads)" = 0 ] || fail "files already archived were downloaded again"

# The Ministry publishes a new day; only that file is fetched.
publish israel-public-transportation.zip '2026-11-21 17:31:41 UTC'
run || fail "archiving a new day failed"
archived 2026/11/21 israel-public-transportation.zip || fail "the new day was not archived"
[ "$(downloads)" = 1 ] || fail "expected one download, got $(downloads)"

# A second version of the 10-day feed on the same day is kept beside the first.
publish Gtfs_10_days.zip '2026-11-20 13:05:00 UTC'
run || fail "archiving a same-day update failed"
archived 2026/11/20/130500 Gtfs_10_days.zip || fail "a second version on the same day was skipped"
archived 2026/11/20/014753 Gtfs_10_days.zip || fail "the first version of the day was lost"

# One feed missing must not cost the others: each format is a fallback for the rest.
rm "$DIR/mot/Gtfs_10_days.zip"; publish RouteNetworksByDate_10_Days.zip '2026-11-22 01:47:53 UTC'
run && fail "a feed the Ministry stopped serving went unreported"
archived 2026/11/22/014753 RouteNetworksByDate_10_Days.zip || fail "one missing feed stopped the others from being archived"

publish Gtfs_10_days.zip '2026-11-23 01:47:53 UTC'; touch "$DIR/s3.down"
run && fail "a failed upload was reported as success"
rm "$DIR/s3.down"
run || fail "the run after an S3 outage failed"
archived 2026/11/23/014753 Gtfs_10_days.zip || fail "a day missed during an S3 outage was not archived later"

echo "gtfs-archive: ok"
