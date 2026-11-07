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

# The watermark comes from BOTH snapshot tables, and that is not belt-and-
# braces. siri_snapshot_seen is fed by an incremental view over the LANDING
# table (ingest/siri.sql), so it only ever records what this node downloaded
# itself. A database loaded from the public dump has 2,370,975 rows in
# siri_snapshot going back to 2022/01/16 and nothing at all in
# siri_snapshot_seen — measured, where seen starts at 2026/05/30, the seam where
# our own backfill began. So reading seen alone, a dump-loaded node answers
# "nothing loaded yet" and exits, which is correct for an empty database and
# wrong for a full one: a node that died between the dump load and the backfill
# could never catch itself up.
newest=$($CH --database "$CH_DB" --query "
  SELECT greatest(
      (SELECT ifNull(max(siri_snapshot_id), '') FROM siri_snapshot_seen FINAL),
      (SELECT ifNull(max(snapshot_id), '') FROM siri_snapshot))")

if [ -z "$newest" ]; then
  echo "nothing loaded yet: a first load is ./up.sh, not a catch-up"
  exit 0
fi

# Two candidates, and the earlier wins.
#
# The watermark day covers the long gap: a dump that ends in May and a today in
# November is six months to fetch, and that is the case the seen-only watermark
# could not even see.
#
# The oldest incomplete day within LOOKBACK covers the short one, which is the
# gap this ingest actually produces: every repair and backfill stops the live
# views for its duration (chain-guard.sh) and the minutes that pass meanwhile
# are lost. Resuming from the newest snapshot forward, as this did before, left
# those holes unreachable forever — measured on 2026-11-07, full days held 959
# and 952 snapshots against the roughly 1,428 the archive has.
#
# The lookback is bounded because an unbounded search costs Hasadna money. A day
# can be short because the archive is short — 2026-08-19 holds 455 snapshots and
# S3 holds 455 — and an unbounded search would rediscover it every hour forever,
# re-listing their bucket on their bill. Seven days heals what a stopped chain
# loses and then lets go. The re-listing is LIST requests only, because
# ClickHouse prunes the glob on `_path` before downloading anything: about 14 a
# run, or $0.05 a month.
watermark_day=$(echo "$newest" | cut -d/ -f1-3 | tr / -)

incomplete_day=$($CH --database "$CH_DB" --query "
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

if [ "$(date -u -d "$watermark_day" +%s)" -lt "$(date -u -d "$incomplete_day" +%s)" ]; then
  from=$watermark_day
else
  from=$incomplete_day
fi

to=$(date -u +%F)

echo "newest snapshot known: $newest"
echo "watermark day: $watermark_day; oldest day short of $MIN_SNAPSHOTS within $LOOKBACK days: $incomplete_day"
echo "catching up $from .. $to"

ENRICH=0 CH_DB="$CH_DB" CH_CLIENT="$CH" "$here/backfill-range.sh" "$from" "$to"
