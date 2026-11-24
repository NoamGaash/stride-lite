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
#
# Tel Aviv-Yafo's weekend lines, "Naim BaSofash", publish a GTFS of their own
# on the city's open-data portal, which the Ministry's files may not include
# (#74). It goes to naim/gtfs/YYYY/MM/DD/HHMMSS/gtfs.zip; the city updates it
# twice a day, at 01:15 and 16:15, and every version is 300 KB.
set -euo pipefail

MOT=https://gtfs.mot.gov.il/gtfsfiles
NAIM=https://opendatasource.tel-aviv.gov.il/OpenData_Ducaments
# URL, prefix in the bucket, and whether a day keeps one version or every one.
FEEDS=(
  "$MOT/israel-public-transportation.zip gtfs day"
  "$MOT/Gtfs_10_days.zip gtfs every"
  "$MOT/RouteNetworksByDate_10_Days.zip gtfs every"
  "$NAIM/gtfs.zip naim/gtfs every"
)
BUCKET=openbus-mot-archive
WORK=${GTFS_WORKDIR:-/var/lib/gtfs-archive}

mkdir -p "$WORK"
failed=0
for feed in "${FEEDS[@]}"; do
  read -r url prefix keep <<<"$feed"
  file=${url##*/}
  if ! modified=$(curl -sSfI --max-time 60 "$url" | tr -d '\r' | sed -n 's/^[Ll]ast-[Mm]odified: //p'); then
    echo "$url: did not answer"; failed=1; continue
  fi
  if [ "$keep" = day ]; then
    key=$prefix/$(date -u -d "$modified" +%Y/%m/%d)/$file
  else
    key=$prefix/$(date -u -d "$modified" +%Y/%m/%d/%H%M%S)/$file
  fi
  if curl -sfI --max-time 60 "https://$BUCKET.s3.amazonaws.com/$key" >/dev/null; then
    continue
  fi
  echo "$file: archiving the copy of $modified as $key"
  if curl -sSf --max-time 1800 -o "$WORK/$file" "$url" \
     && aws s3 cp "$WORK/$file" "s3://$BUCKET/$key" --only-show-errors; then
    :
  else
    echo "$file: not archived; the next run tries again"; failed=1
  fi
  rm -f "$WORK/$file"
done
exit "$failed"
