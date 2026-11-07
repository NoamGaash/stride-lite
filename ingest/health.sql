-- Per-day data health, so "is this day trustworthy?" is a lookup and not an
-- investigation.
--
-- This exists because the failure it reports actually happened here and nothing
-- noticed for three weeks: two enrichment passes ran at once, and since ids are
-- minted as max(id) + row_number(), both handed out the same numbers. Every day
-- from 2026-07-26 to 2026-08-23 ended up with duplicate rows, and on 2026-06-15
-- 704,018 ids each covered two different readings. See ingest/verify.sql, which
-- is the gate; this is the record.
--
-- It is also the thing production does not have. Finding 13 is twenty months of
-- "zero buses ran" that reads as data rather than as an outage, because nothing
-- in the API distinguishes the two. A day here says how much arrived, how much
-- was derived from it, and whether its ids are sound, so the three are telling
-- apart.
--
-- A table and not a query: the duplicate columns need uniqExact over a day's
-- rows, which is fine once a day and not fine per request on a public endpoint.
-- Measured, the two ride columns cost 1.4 s for a day of 120,405 rides.
--
-- ReplacingMergeTree(measured_at) on `day`, so re-measuring a day after a
-- repair supersedes the old verdict instead of appending a second one.
--
-- DDL only, like ingest/enrich.sql: enrich-once.sql measures the day it just
-- loaded, and the view below keeps the live tail current.
--
--   clickhouse client -d stride --multiquery < ingest/health.sql

CREATE OR REPLACE VIEW ingest_day_health_src AS
WITH
    -- The day's rides by SERVICE date, out of journey_ref, which begins
    -- 'YYYY-MM-DD-'. Not by scheduled_start_time, which the `rides` column
    -- below still uses: that one is an argMin the feed can revise, while a
    -- journey_ref is fixed and the `by_natural_key` projection is sorted on it,
    -- so this range is a seek and not a scan of 118 million rides.
    mine AS (
        SELECT id FROM siri_ride
        WHERE journey_ref >= toString({day:Date}) AND journey_ref < toString({day:Date} + 1)
    )
SELECT
    {day:Date} AS day,
    (SELECT count() FROM siri_snapshot_seen FINAL
       WHERE siri_snapshot_id LIKE formatDateTime({day:Date}, '%Y/%m/%d') || '/%') AS snapshots,
    -- One per minute is what the requester attempts, so 1440 is the ceiling and
    -- a finished day is judged against it. Today is judged against the minutes
    -- that have actually happened, which is the only reason this is a column
    -- and not a constant somebody could have written down once.
    --
    -- It is a ceiling and NOT a floor, deliberately. A healthy day arrives at
    -- about 1,430 because a few minutes fail upstream, but 2026-08-19 holds 455
    -- and that is not our failure either: the bucket listing returns
    -- KeyCount 455, so the archive itself holds 455. A consumer that treats any
    -- shortfall as a lost download will be wrong about that day.
    toUInt32(if({day:Date} < today(), 1440, toHour(now()) * 60 + toMinute(now()))) AS snapshots_expected,
    loc.rows AS vehicle_locations,
    loc.rows - loc.ids AS duplicate_ids,
    -- The measure that the id checks are structurally blind to, and the reason
    -- it is here: 2026-08-16 came out of an id-only repair with 15,189,121 rows,
    -- 15,189,121 distinct ids and 7,294,846 distinct readings. `duplicate_ids`
    -- said 0. A ratio over 1.01 is damage; see mode 2 in ingest/verify.sql for
    -- why the threshold is not zero — 785 duplicate readings an hour are
    -- legitimate, and this column counts those too.
    loc.rows - loc.readings AS duplicate_readings,
    rides.n AS rides,
    rides.measured AS rides_with_duration,
    rides.linked AS rides_linked_to_gtfs,
    -- Per-table, because `duplicate_ids` above is siri_vehicle_location's alone
    -- and a reader could not tell. These two are the upstream cause rather than
    -- the symptom: a ride stop that exists twice under one natural key makes
    -- every reading through it land twice, which is what doubled 2026-08-16.
    -- Both are exact and both should be zero — the enrichment dedups on exactly
    -- these keys, so a second row under one is never legitimate.
    (SELECT count() - uniqExact(id) FROM siri_ride
       WHERE journey_ref >= toString({day:Date}) AND journey_ref < toString({day:Date} + 1)
    ) AS duplicate_ride_ids,
    -- The one measure here that a projection could lie about. A siri_ride_id
    -- filter reads `by_siri_ride`, and a lightweight delete leaves that
    -- projection serving the rows it removed — measured, 1,732,181 against the
    -- table's 2,860. A health verdict has to come from the table.
    (SELECT count() - uniqExact((siri_ride_id, siri_stop_id, `order`))
       FROM siri_ride_stop WHERE siri_ride_id IN (SELECT id FROM mine)
       SETTINGS optimize_use_projections = 0
    ) AS duplicate_ride_stop_keys,
    now() AS measured_at
FROM
(
    SELECT count() AS rows, uniqExact(id) AS ids,
           uniqExact((siri_snapshot_id, siri_ride_stop_id, recorded_at_time)) AS readings
    FROM siri_vehicle_location
    WHERE recorded_at_time >= toDateTime({day:Date})
      AND recorded_at_time < toDateTime({day:Date}) + INTERVAL 1 DAY
) AS loc,
(
    SELECT count() AS n,
           countIf(id IN (SELECT siri_ride_id FROM siri_ride_duration)) AS measured,
           countIf(scheduled_time_gtfs_ride_id IS NOT NULL) AS linked
    FROM siri_ride
    WHERE scheduled_start_time >= toDateTime({day:Date})
      AND scheduled_start_time < toDateTime({day:Date}) + INTERVAL 1 DAY
) AS rides;

-- Yesterday, four times a day. Yesterday and not today because a day is only
-- worth judging once its rides have finished reporting, which is the same reason
-- enrich_duration leaves its last six hours to the next run. Re-measuring the
-- same day is free of consequence: ReplacingMergeTree(measured_at) keeps the
-- newest verdict, which is what makes a day recoverable after a repair.
CREATE OR REPLACE MATERIALIZED VIEW ingest_day_health_daily
REFRESH EVERY 6 HOUR DEPENDS ON enrich_duration
APPEND TO ingest_day_health AS
SELECT * FROM ingest_day_health_src(day = today() - 1);
