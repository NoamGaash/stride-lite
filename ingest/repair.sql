-- The delete half of a repair: takes a date range back to the state it was in
-- before anything was derived from it, so ingest/enrich-once.sql can derive it
-- again. Driven by ingest/repair-range.sh, which supplies the range and then
-- does the re-deriving day by day.
--
-- Nothing here reads S3. That is the point of the file: the landing table is
-- the only input a re-derivation needs, so a repair of a month we still hold
-- costs Hasadna nothing. A full day of stride-siri-requester is 1,428 objects
-- and 217 MiB, which is $0.022 of their egress; this is $0.
--
-- What "damaged" means, concretely. `id` is minted as max(id) + row_number().
-- Two passes that overlap read the same starting max and mint the same numbers,
-- so one id ends up covering two different readings and stops being a key.
-- Measured today: 9,161,623 duplicate ids in siri_ride_stop, 67,634 in
-- siri_ride, and millions of duplicate rows a day in siri_vehicle_location.
--
-- The unit of repair is the SNAPSHOT and not the calendar day. A snapshot's
-- readings are not confined to its own day: measured over 2026/08, a reading
-- can be 22.7 hours older than the snapshot that carried it, and 11,855 of
-- them are dated more than a day into the future (finding 14 — the ministry's
-- clock, not ours). So every predicate below selects on the snapshot, never on
-- recorded_at_time, and that is also the answer to whether siri_vehicle_location
-- should be partitioned by month: a time partition would not contain a day's
-- damage, so it would not make this any cheaper. Measured, finding the rows
-- takes 2.7 s as it stands.
--
-- Rides and ride stops are only deleted when EVERY row sharing the duplicated
-- id belongs to the range. A duplicated id whose two rows straddle the range's
-- edge cannot be repaired from inside it: re-deriving needs the landing rows of
-- both, and deleting half the pair would orphan the locations of the other
-- half. Those are left alone and reported, which is why the range given should
-- be the whole damaged span and not a convenient slice of it.
--
--   clickhouse client -d prod --multiquery \
--     --param_from=2026-08-01 --param_to=2026-08-23 < ingest/repair.sql

-- Same first statement as enrich-once.sql, and for the same reason: a repair is
-- an enrichment pass, so running it while the chain is enabled would recreate
-- exactly the damage it is undoing.
SELECT throwIf(
    count() > 0,
    'the enrichment chain is enabled: SYSTEM STOP VIEW it first, or use ingest/repair-range.sh'
) FROM system.view_refreshes
WHERE database = currentDatabase() AND startsWith(view, 'enrich_') AND status != 'Disabled';

-- Refuse a range we cannot re-derive. Deleting rows whose landing copy is gone
-- would turn damaged data into missing data, which is worse: a duplicate id is
-- visible and a hole is not.
SELECT throwIf(
    count() > 0,
    'some day in the range has no landing rows: re-fetch it before repairing, or narrow the range'
) FROM (
    SELECT {from:Date} + number AS day
    FROM numbers(dateDiff('day', {from:Date}, {to:Date}) + 1)
    WHERE day NOT IN (
        SELECT toDate(replaceAll(substring(siri_snapshot_id, 1, 10), '/', '-'))
        FROM siri_vehicle_location_raw
        GROUP BY siri_snapshot_id
    )
);

-- The sets, materialised rather than inlined. Each delete below changes a table
-- a later one reads, so the membership has to be decided once, up front, while
-- every row still exists.

DROP TABLE IF EXISTS repair_snapshot SYNC;
CREATE TABLE repair_snapshot ENGINE = MergeTree ORDER BY id AS
SELECT id
FROM siri_snapshot
WHERE snapshot_id >= formatDateTime({from:Date}, '%Y/%m/%d')
  AND snapshot_id < formatDateTime({to:Date} + 1, '%Y/%m/%d');

-- Every ride the range observed, by natural key out of the landing table —
-- the same (siri_route_id, journey_ref, vehicle_ref) identity enrich_ride_src
-- uses. Restricted on journey_ref because a journey_ref carries its own date,
-- which is what makes the `by_natural_key` projection a seek rather than a scan
-- of 118 million rides.
DROP TABLE IF EXISTS repair_ride_seen SYNC;
CREATE TABLE repair_ride_seen ENGINE = MergeTree ORDER BY id AS
WITH refs AS (
    SELECT DISTINCT concat(data_frame_ref, '-', dated_vehicle_journey_ref) AS journey_ref
    FROM siri_vehicle_location_raw
    WHERE siri_snapshot_id >= formatDateTime({from:Date}, '%Y/%m/%d')
      AND siri_snapshot_id < formatDateTime({to:Date} + 1, '%Y/%m/%d')
)
SELECT id FROM siri_ride WHERE journey_ref IN (SELECT journey_ref FROM refs);

-- Rides whose id is not a key. `journey_ref` begins with the service date —
-- verified against the damaged rides, every one of which reads
-- 'YYYY-MM-DD-<journey>' — so the range test is a string comparison and needs
-- no second table. The id band keeps the GROUP BY on the sort key: unrestricted
-- the same shape over siri_ride_stop took 3 m 47 s, and bounded, 5 s.
DROP TABLE IF EXISTS repair_ride_broken SYNC;
CREATE TABLE repair_ride_broken ENGINE = MergeTree ORDER BY id AS
WITH band AS (SELECT min(id) AS lo, max(id) AS hi FROM repair_ride_seen)
SELECT id
FROM siri_ride
WHERE id >= (SELECT lo FROM band) AND id <= (SELECT hi FROM band)
GROUP BY id
HAVING count() > 1
   AND countIf(journey_ref >= toString({from:Date}) AND journey_ref < toString({to:Date} + 1)) = count();

-- Ride stops to delete, which is three groups and not one. The first version
-- of this file had only the second, and that is why 2026-08-16 came out of a
-- repair holding every reading twice: its ids were all unique and 1,287,638 of
-- its stops still existed twice under one natural key, so each landing reading
-- joined to both copies and produced two locations. See mode 2 in verify.sql.
--
--   a. the natural key appears more than once. All of its rows go, and the
--      re-derivation mints exactly one — enrich_ride_stop_src dedups on this
--      same tuple, so a second row under it is never legitimate.
--   b. the id is not a key, provided every row under that id belongs to this
--      range. One whose rows straddle the edge is left alone and reported.
--   c. the stop hangs off a ride that is about to be deleted, whose id is
--      re-minted when it is re-derived.
DROP TABLE IF EXISTS repair_ride_stop_broken SYNC;
CREATE TABLE repair_ride_stop_broken ENGINE = MergeTree ORDER BY id AS
WITH
    mine AS (SELECT id FROM repair_ride_seen),
    stops AS (
        SELECT id, siri_ride_id, siri_stop_id, `order`
        FROM siri_ride_stop
        WHERE siri_ride_id IN (SELECT id FROM mine)
    ),
    band AS (SELECT min(id) AS lo, max(id) AS hi FROM stops),
    dup_key AS (
        SELECT siri_ride_id, siri_stop_id, `order`
        FROM stops
        GROUP BY siri_ride_id, siri_stop_id, `order`
        HAVING count() > 1
    ),
    dup_id AS (
        SELECT id
        FROM siri_ride_stop
        WHERE id >= (SELECT lo FROM band) AND id <= (SELECT hi FROM band)
        GROUP BY id
        HAVING count() > 1
           AND countIf(siri_ride_id IN (SELECT id FROM mine)) = count()
    )
SELECT id
FROM stops
WHERE (siri_ride_id, siri_stop_id, `order`) IN (SELECT siri_ride_id, siri_stop_id, `order` FROM dup_key)
   OR id IN (SELECT id FROM dup_id)
   OR siri_ride_id IN (SELECT id FROM repair_ride_broken);

-- Now the deletes, in the one order that works: durations before the rides they
-- name, ride stops before the rides they hang off, and the fact table last.
-- Lightweight deletes, because siri_vehicle_location is 120 GiB in a single
-- partition and a mutation would rewrite all of it.

DELETE FROM siri_ride_duration WHERE siri_ride_id IN (SELECT id FROM repair_ride_seen);

-- These two carry projections, and a lightweight delete refuses to touch a
-- table with one until it is told what to do about them. The decision is
-- `rebuild` and it lives on the table in db/schema.sql, not here: it is a
-- MergeTree setting, so a query-level SETTINGS clause, a `SET` and a client
-- flag are all read and then ignored — measured, all three still fail with
-- "mode is set to THROW".
--
-- `rebuild` rather than `drop` because the projections are not decoration:
-- `by_natural_key` is what makes the ride lookup above a seek and
-- `by_siri_ride` the same for stops, and `drop` would leave db/projections.sql
-- to be reapplied by hand. It is affordable because the damage sits at the top
-- of the id space: measured, every row of the damaged band is in 7 parts
-- totalling 940 MiB out of 61 GiB.
DELETE FROM siri_ride_stop WHERE id IN (SELECT id FROM repair_ride_stop_broken);

DELETE FROM siri_ride WHERE id IN (SELECT id FROM repair_ride_broken);

DELETE FROM siri_vehicle_location WHERE siri_snapshot_id IN (SELECT id FROM repair_snapshot);

-- The marks are NOT cleared here. siri_feed offers a snapshot again the moment
-- its mark is gone, and siri_feed has no date filter — so clearing the whole
-- range at once would make the first day's pass try to re-derive all of it in
-- one query. repair-range.sh clears one day, derives it, verifies it, and only
-- then moves on, which is also what keeps scheduled_start_time right: it is an
-- argMin over the snapshots in the batch, so the batches have to arrive in
-- order.

SELECT
    (SELECT count() FROM repair_snapshot) AS snapshots_to_rederive,
    (SELECT count() FROM repair_ride_seen) AS rides_observed,
    (SELECT count() FROM repair_ride_broken) AS rides_deleted,
    (SELECT count() FROM repair_ride_stop_broken) AS ride_stops_deleted;
