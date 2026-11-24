-- Moves the GTFS links production did make into siri_ride_gtfs, the table the
-- API and gtfs_rides_agg_by_hour read them from since #38. Until now they were
-- only in siri_ride, which nothing reads for links, so every ride the dump
-- brought answered gtfs_ride_id: null, and /gtfs_rides_agg/group_by reported 0
-- actual rides for 2024-08-14 where production reports 608 of 909 for operator
-- 2 (differential suite, 2026-11-23). Production's linking stopped in
-- October 2024 (finding 1 in docs/FINDINGS.md), so this is mostly 2023-2024.
--
-- The same move 001 made for durations, with one boundary of its own: a date
-- the live ingest has seen belongs to enrich_gtfs_link (ingest/gtfs-link.sql),
-- which links a date once and then treats it as done. Seeding such a date would
-- stop that view from ever linking the rest of it, so those dates are left to
-- it. journey_date is derived as that view derives it.
--
-- siri_snapshot_seen belongs to ingest/siri.sql, which a deploy applies after
-- the migrations; on a new database it does not exist yet. Created here as
-- that file creates it, so its own IF NOT EXISTS then does nothing.
--
-- Re-runnable, per db/migrations/README.md: the NOT IN on siri_ride_id makes a
-- second pass insert nothing.
CREATE TABLE IF NOT EXISTS siri_snapshot_seen
(
    siri_snapshot_id String
)
ENGINE = ReplacingMergeTree
ORDER BY siri_snapshot_id;

INSERT INTO siri_ride_gtfs
SELECT id AS siri_ride_id, journey_date,
       journey_gtfs_ride_id, route_gtfs_ride_id, gtfs_ride_id, scheduled_time_gtfs_ride_id
FROM (
    SELECT id,
           ifNull(toDateOrNull(substring(journey_ref, 1, 10)),
                  toDate(scheduled_start_time)) AS journey_date,
           journey_gtfs_ride_id, route_gtfs_ride_id, gtfs_ride_id, scheduled_time_gtfs_ride_id
    FROM siri_ride
    WHERE journey_gtfs_ride_id IS NOT NULL
       OR route_gtfs_ride_id IS NOT NULL
       OR gtfs_ride_id IS NOT NULL
       OR scheduled_time_gtfs_ride_id IS NOT NULL
)
WHERE journey_date NOT IN (
        SELECT DISTINCT toDate(replaceAll(substring(siri_snapshot_id, 1, 10), '/', '-'))
        FROM siri_snapshot_seen)
  AND id NOT IN (SELECT siri_ride_id FROM siri_ride_gtfs);
