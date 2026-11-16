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

-- Every snapshot the requester wrote, empty ones included. siri_snapshot_seen
-- is derived from inserted rows, so a snapshot with no vehicle in it never
-- reaches it, and a quiet night read as a download cut short.
CREATE TABLE IF NOT EXISTS siri_snapshot_listed
(
    siri_snapshot_id String
)
ENGINE = ReplacingMergeTree
ORDER BY siri_snapshot_id;

CREATE OR REPLACE VIEW siri_snapshot_listed_by_day AS
SELECT toDate(parseDateTime(substring(siri_snapshot_id, 1, 10), '%Y/%m/%d')) AS day,
       count() AS listed
FROM siri_snapshot_listed FINAL
GROUP BY day;

-- Lists the newest measured day not listed yet, one day per run. Format One
-- reads no file: a day costs two S3 LIST requests and no download. With
-- nothing left to list, the prefix matches no key.
CREATE OR REPLACE MATERIALIZED VIEW siri_snapshot_listing
REFRESH EVERY 5 MINUTE
APPEND TO siri_snapshot_listed AS
SELECT DISTINCT replaceRegexpOne(_path, '^[^/]+/stride-siri-requester/(.*)\\.br$', '\\1') AS siri_snapshot_id
FROM s3(
    (SELECT concat('https://openbus-stride-public.s3.eu-west-1.amazonaws.com/stride-siri-requester/',
                   ifNull(formatDateTime(maxOrNull(day), '%Y/%m/%d'), 'none'), '/*/*.br')
     FROM ingest_day_health FINAL
     WHERE snapshots > 0 AND day NOT IN (SELECT day FROM siri_snapshot_listed_by_day)),
    NOSIGN, One)
SETTINGS glob_expansion_max_elements = 9999999;

CREATE OR REPLACE VIEW ingest_day_health_src AS
SELECT
    {day:Date} AS day,
    (SELECT uniqExact(siri_snapshot_id) FROM (
       SELECT siri_snapshot_id FROM siri_snapshot_seen
       WHERE siri_snapshot_id LIKE formatDateTime({day:Date}, '%Y/%m/%d') || '/%'
       UNION ALL
       SELECT siri_snapshot_id FROM siri_snapshot_listed
       WHERE siri_snapshot_id LIKE formatDateTime({day:Date}, '%Y/%m/%d') || '/%')) AS snapshots,
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
           countIf(id IN (SELECT siri_ride_id FROM siri_ride_gtfs
                          WHERE gtfs_ride_id IS NOT NULL)) AS linked
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

-- The day above is measured before its rides are linked: ingest/gtfs-link.sql
-- waits until two days later, so that first verdict counts no links. This is
-- the day to measure again: the newest one whose verdict still says no ride was
-- linked although siri_ride_gtfs now links some, or whose snapshot count is
-- below what listing the bucket has since found. It also walks back through
-- days measured during a backfill, one per run.
CREATE OR REPLACE VIEW ingest_day_health_resettle AS
WITH (SELECT maxOrNull(h.day) FROM ingest_day_health AS h FINAL
      LEFT JOIN siri_snapshot_listed_by_day AS l ON l.day = h.day
      WHERE (h.rides_linked_to_gtfs = 0
             AND h.day IN (SELECT DISTINCT journey_date FROM siri_ride_gtfs
                           WHERE gtfs_ride_id IS NOT NULL))
         OR h.snapshots < l.listed) AS unsettled
SELECT * FROM ingest_day_health_src(day = ifNull(unsettled, toDate(0)))
WHERE unsettled IS NOT NULL;

CREATE OR REPLACE MATERIALIZED VIEW ingest_day_health_resettle_run
REFRESH EVERY 10 MINUTE
APPEND TO ingest_day_health AS
SELECT * FROM ingest_day_health_resettle;
