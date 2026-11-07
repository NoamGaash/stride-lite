#!/usr/bin/env bash
# Heals a gap of any length, so a machine that was off for a week comes back and
# completes itself.
#
# ingest/siri.sql looks at the running hour and the one before it. That covers a
# missed refresh or a reboot and nothing longer, because S3 has no "since then"
# pattern — the path is a glob and the glob is an hour. So the long gap needs
# something that knows where it stopped, and that is this.
#
# Where it stopped is derived from what was actually inserted, so it cannot
# disagree with the data. But "where did it stop" is the wrong question, and
# asking it cost us a third of the live feed.
#
# The old version took the newest snapshot id and caught up from that DAY
# forward, so a hole BEHIND the newest snapshot was never revisited — and holes
# behind it are exactly what this ingest produces, because every repair and
# every backfill stops the live views for its duration (chain-guard.sh) and the
# minutes that pass meanwhile are lost. Measured on 2026-11-07: full days held
# 959 and 952 snapshots against the roughly 1,428 the archive has, about two
# thirds, and no number of catch-ups would have closed it.
#
# So it resumes from the OLDEST incomplete day, and the lookback is bounded for
# a reason that costs money. A day can be short because the archive is short —
# 2026-08-19 holds 455 snapshots and S3 holds 455 — and an unbounded search
# would rediscover that day every hour forever, re-listing somebody else's
# bucket on their bill. Seven days heals what a stopped chain loses and then
# lets go. The re-listing is LIST requests only, because ClickHouse prunes the
# glob on `_path` before downloading anything: about 14 a run, or $0.05 a month.
LOOKBACK=${CATCHUP_LOOKBACK_DAYS:-7}
MIN_SNAPSHOTS=${MIN_SNAPSHOTS:-1400}

newest=$($CH --database "$CH_DB" --query "
  SELECT ifNull(max(siri_snapshot_id), '') FROM siri_snapshot_seen FINAL")

if [ -z "$newest" ]; then
  echo "nothing loaded yet: a first load is ./up.sh, not a catch-up"
  exit 0
fi

from=$($CH --database "$CH_DB" --query "
  WITH toDate(today() - $LOOKBACK) AS floor
  SELECT ifNull(min(day), today())
  FROM (
      SELECT floor + number AS day
      FROM numbers(dateDiff('day', floor, today()) + 1)
  )
  WHERE (
      SELECT count() FROM siri_snapshot_seen FINAL
      WHERE siri_snapshot_id LIKE formatDateTime(day, '%Y/%m/%d') || '/%'
  ) < $MIN_SNAPSHOTS")

to=$(date -u +%F)

echo "newest snapshot loaded: $newest"
echo "oldest day short of $MIN_SNAPSHOTS within $LOOKBACK days: $from"
echo "catching up $from .. $to"

ENRICH=0 CH_DB="$CH_DB" CH_CLIENT="$CH" "$here/backfill-range.sh" "$from" "$to"
