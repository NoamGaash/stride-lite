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
-- A table and not a query: `duplicate_ids` needs uniqExact over a day's rows,
-- which is fine once a day and not fine per request on a public endpoint.
--
-- ReplacingMergeTree(measured_at) on `day`, so re-measuring a day after a
-- repair supersedes the old verdict instead of appending a second one.
--
-- DDL only, like ingest/enrich.sql: enrich-once.sql measures the day it just
-- loaded, and the view below keeps the live tail current.
--
--   clickhouse client -d stride --multiquery < ingest/health.sql

CREATE OR REPLACE VIEW ingest_day_health_src AS
SELECT
    {day:Date} AS day,
    (SELECT count() FROM siri_snapshot_seen FINAL
       WHERE siri_snapshot_id LIKE formatDateTime({day:Date}, '%Y/%m/%d') || '/%') AS snapshots,
    loc.rows AS vehicle_locations,
    loc.rows - loc.ids AS duplicate_ids,
    rides.n AS rides,
    rides.measured AS rides_with_duration,
    rides.linked AS rides_linked_to_gtfs,
    now() AS measured_at
FROM
(
    SELECT count() AS rows, uniqExact(id) AS ids
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
