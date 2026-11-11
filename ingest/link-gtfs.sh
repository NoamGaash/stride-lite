#!/usr/bin/env bash
# Links the SIRI rides whose journey_ref falls on FROM..TO to their GTFS rides,
# a day at a time, into siri_ride_gtfs. For history, and for days whose GTFS
# arrived after the hourly enrich_gtfs_link had moved past them.
#
#   ingest/link-gtfs.sh 2026-07-09 2026-11-11          # rides not yet linked
#   ingest/link-gtfs.sh 2026-11-08 2026-11-10 relink   # all of them, again
set -euo pipefail
cd "$(dirname "$0")/.."
CH_DB=${CH_DB:-stride}
CH=${CH_CLIENT:-clickhouse client}
from=$1 to=$2 relink=${3:-}

ch() { $CH --database "$CH_DB" --param_day="$day" "$@" </dev/null; }

day=$from
while [[ ! "$day" > "$to" ]]; do
  if [ "$relink" = relink ]; then
    ch --query "
      DELETE FROM siri_ride_gtfs WHERE siri_ride_id IN (
        SELECT id FROM siri_ride
        WHERE journey_ref >= toString({day:Date}) AND journey_ref < toString({day:Date} + 1))"
  fi
  ch --query "
    INSERT INTO siri_ride_gtfs
    SELECT * FROM enrich_gtfs_link_src(from = {day:Date}, to = {day:Date})"
  echo "   $day linked"
  day=$(date -u -d "$day +1 day" +%F)
done
