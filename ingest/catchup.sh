#!/usr/bin/env bash
# Heals a gap of any length, so a machine that was off for a week comes back and
# completes itself.
#
# ingest/siri.sql looks at the running hour and the one before it. That covers a
# missed refresh or a reboot and nothing longer, because S3 has no "since then"
# pattern — the path is a glob and the glob is an hour. So the long gap needs
# something that knows where it stopped, and that is this.
#
# Where it stopped is not tracked beside the data: it is the newest snapshot id
# in siri_snapshot_seen, which is derived from what was actually inserted and so
# cannot disagree with it.
#
# Landing table only, deliberately. The refreshable chain in ingest/enrich.sql
# reads the landing table whole every minute and dedups with NOT IN, so it picks
# these rows up by itself, and it has to stay the only thing that does: it
# assigns ids as max(id) + row_number(), and two passes running at once hand out
# the same ones.
#
# Runs at boot and once an hour from cron, under flock, because a catch-up of a
# week takes hours and the hourly tick must not start a second one.
set -euo pipefail

CH_DB=${CH_DB:-stride}
CH=${CH_CLIENT:-clickhouse client}
here="$(cd "$(dirname "$0")" && pwd)"

newest=$($CH --database "$CH_DB" --query "
  SELECT ifNull(max(siri_snapshot_id), '') FROM siri_snapshot_seen FINAL")

if [ -z "$newest" ]; then
  echo "nothing loaded yet: a first load is ./up.sh, not a catch-up"
  exit 0
fi

# 'YYYY/MM/DD/HH/MM' -> 'YYYY-MM-DD'
from=$(echo "$newest" | cut -d/ -f1-3 | tr / -)
to=$(date -u +%F)

echo "newest snapshot loaded: $newest"
echo "catching up $from .. $to"

ENRICH=0 CH_DB="$CH_DB" CH_CLIENT="$CH" "$here/backfill-range.sh" "$from" "$to"
