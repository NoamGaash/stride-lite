#!/usr/bin/env bash
# Copies the Ministry of Transport's GTFS files to the archive bucket, keyed by
# the file's own Last-Modified (UTC):
#   s3://openbus-mot-archive/gtfs/YYYY/MM/DD/israel-public-transportation.zip
#   s3://openbus-mot-archive/gtfs/YYYY/MM/DD/HHMMSS/<file>   (the 10-day format)
# The first is the layout of Hasadna's gtfs_archive, kept so a reader of theirs
# can read ours; it holds one version a day, as theirs does. Nothing reads the
# 10-day format yet, so it carries the time too and every version is kept. Run
# every few hours by infra/node/systemd/gtfs-archive.timer; a version already
# archived is skipped.
#
# The Ministry serves only its newest files, so a day nobody copies is gone.
# Both formats are kept: the current one, and the 10-day feed with its route
# network that is to replace it (hasadna/open-bus-gtfs-etl#25). Each is a
# fallback for the other, and the new one gives the ingest an archive to be
# tested against before the switch.
set -euo pipefail

FILES=(israel-public-transportation.zip Gtfs_10_days.zip RouteNetworksByDate_10_Days.zip)
SOURCE=https://gtfs.mot.gov.il/gtfsfiles
BUCKET=openbus-mot-archive
WORK=${GTFS_WORKDIR:-/var/lib/gtfs-archive}

mkdir -p "$WORK"
failed=0
for file in "${FILES[@]}"; do
  if ! modified=$(curl -sSfI --max-time 60 "$SOURCE/$file" | tr -d '\r' | sed -n 's/^[Ll]ast-[Mm]odified: //p'); then
    echo "$file: the Ministry did not answer"; failed=1; continue
  fi
  if [ "$file" = israel-public-transportation.zip ]; then
    key=gtfs/$(date -u -d "$modified" +%Y/%m/%d)/$file
  else
    key=gtfs/$(date -u -d "$modified" +%Y/%m/%d/%H%M%S)/$file
  fi
  if curl -sfI --max-time 60 "https://$BUCKET.s3.amazonaws.com/$key" >/dev/null; then
    continue
  fi
  echo "$file: archiving the copy of $modified as $key"
  if curl -sSf --max-time 1800 -o "$WORK/$file" "$SOURCE/$file" \
     && aws s3 cp "$WORK/$file" "s3://$BUCKET/$key" --only-show-errors; then
    :
  else
    echo "$file: not archived; the next run tries again"; failed=1
  fi
  rm -f "$WORK/$file"
done
exit "$failed"
