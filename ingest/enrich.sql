-- Enrichment: derive the API's typed tables from the raw SIRI feed.
--
-- `siri_vehicle_location_raw` is the MOT feed as it arrives — every field a
-- string, no foreign keys. The API serves typed tables joined by integer id.
-- This file is the derivation, and it is what makes the ingest end to end.
--
-- Two rules decide the shape of everything below.
--
-- 1. Public-transport data is byte-for-byte: coordinates, bearing, velocity,
--    distances, line and operator refs, journey refs, stop codes and times all
--    come through unchanged. Our surrogate ids are ours, so they are assigned
--    densely from max(id) rather than reproduced from production's sequences.
--
-- 2. A ride's identity is (siri_route_id, journey_ref, vehicle_ref) and NOT its
--    scheduled_start_time. This is not inferred: open-bus-siri-etl's
--    `get_or_create_siri_rides` looks a ride up by exactly those three, and sets
--    scheduled_start_time only on the row it creates. Confirmed against the
--    dump, where the three are already unique over 123,622 rides in a day.
--    Keying on the departure time instead splits one ride into several whenever
--    the feed revises it — measured, 65 rows in a single minute.
--
--    Because the attribute is frozen at creation, the argMin is over
--    siri_snapshot_id and not over recorded_at_time: the value upstream keeps is
--    the one carried by the first snapshot that mentioned the ride, and
--    snapshots are processed in snapshot order. A ride first seen before the
--    loaded window therefore keeps a departure time this database cannot
--    derive, which is what a backfill has to load oldest-hour-first to avoid.
--
-- 3. Every join to a big table is restricted to the batch first. ClickHouse
--    hashes a join's right side whole, so joining siri_ride_stop unrestricted
--    read 2.89 billion rows in 545 s and had not finished. The restriction is
--    always by journey_ref, for the reason given under the ride step.
--
-- Each step is a plain view holding the SELECT, and a refreshable view that
-- appends it. `ingest/enrich-once.sql` runs the same bodies as INSERTs for a
-- backfill, so the logic exists once.
--
-- Apply with:  clickhouse client --database stride --multiquery < ingest/enrich.sql

-- Which snapshots have already been turned into typed rows. Maintained from the
-- data itself by an incremental view, exactly as `siri_snapshot_seen` is for the
-- ingest, so the two cannot disagree and a crash cannot desynchronise them.
CREATE TABLE IF NOT EXISTS siri_snapshot_enriched
(
    siri_snapshot_id Int32
)
ENGINE = ReplacingMergeTree
ORDER BY siri_snapshot_id;

CREATE MATERIALIZED VIEW IF NOT EXISTS siri_snapshot_enriched_mv
TO siri_snapshot_enriched
AS
SELECT siri_snapshot_id
FROM siri_vehicle_location
GROUP BY siri_snapshot_id;

-- The highest id handed out so far in siri_vehicle_location.
--
-- It exists because `max(id)` on that table is a full scan: it is sorted by
-- (recorded_at_time, id), so the maximum of the second key is not at a known
-- place. Measured at 149 s over 6.5 billion rows, every refresh, even when
-- there was nothing to insert. The other tables are sorted by id, so their
-- max(id) reads one granule and needs none of this.
CREATE TABLE IF NOT EXISTS siri_vehicle_location_max_id
(
    marker UInt8,
    max_id AggregateFunction(max, Int64)
)
ENGINE = AggregatingMergeTree
ORDER BY marker;

CREATE MATERIALIZED VIEW IF NOT EXISTS siri_vehicle_location_max_id_mv
TO siri_vehicle_location_max_id
AS
SELECT 1 AS marker, maxState(id) AS max_id
FROM siri_vehicle_location;

-- One parsing view, read by all six steps. It casts the feed's strings once
-- and drops readings with no coordinates, which is what production does:
-- measured, zero NULL locations in 432,143 production rows for an hour, against
-- 407 empty ones in 335,227 raw rows. Keeping them produced four readings the
-- production API does not return.
CREATE OR REPLACE VIEW siri_feed AS
SELECT
    siri_snapshot_id,
    recorded_at_time,
    toInt32(line_ref) AS line_ref,
    toInt32(operator_ref) AS operator_ref,
    concat(data_frame_ref, '-', dated_vehicle_journey_ref) AS journey_ref,
    origin_aimed_departure_time AS scheduled_start_time,
    vehicle_ref,
    toInt32(stop_point_ref) AS stop_code,
    toInt32(stop_order) AS stop_order,
    toFloat64(vehicle_location_longitude) AS lon,
    toFloat64(vehicle_location_latitude) AS lat,
    toInt32(bearing) AS bearing,
    toInt32(velocity) AS velocity,
    toInt32(distance_from_stop) AS distance_from_journey_start
FROM siri_vehicle_location_raw
WHERE vehicle_location_longitude != '' AND vehicle_location_latitude != ''
  -- Snapshots already turned into typed rows are excluded here rather than at
  -- each step, so a refresh costs what arrived since the last one instead of
  -- rereading the whole landing table. Without this a no-op refresh still took
  -- 2 m 33 s once the table held two hours of feed, and it would only grow.
  AND siri_snapshot_id NOT IN (
      SELECT snapshot_id FROM siri_snapshot
      WHERE id IN (SELECT siri_snapshot_id FROM siri_snapshot_enriched FINAL)
  );

-- The dimensions. Small enough that `NOT IN` over the whole table is a
-- non-issue: 17.8k routes and 36.5k stops in production today.

CREATE OR REPLACE VIEW enrich_route_src AS
SELECT
    (SELECT ifNull(max(id), 0) FROM siri_route)
        + toInt32(row_number() OVER (ORDER BY line_ref, operator_ref)) AS id,
    line_ref,
    operator_ref
FROM (
    SELECT DISTINCT line_ref, operator_ref FROM siri_feed
) AS fresh
WHERE (line_ref, operator_ref) NOT IN (SELECT (line_ref, operator_ref) FROM siri_route);

CREATE OR REPLACE VIEW enrich_stop_src AS
SELECT
    (SELECT ifNull(max(id), 0) FROM siri_stop)
        + toInt32(row_number() OVER (ORDER BY code)) AS id,
    code
FROM (SELECT DISTINCT stop_code AS code FROM siri_feed) AS fresh
WHERE code NOT IN (SELECT code FROM siri_stop);

-- `num_successful_parse_vehicle_locations` is the snapshot's own row count,
-- which is what the column means. The remaining ETL bookkeeping columns stay
-- NULL: they describe an Airflow task's progress, and there is no task.
CREATE OR REPLACE VIEW enrich_snapshot_src AS
SELECT
    (SELECT ifNull(max(id), 0) FROM siri_snapshot)
        + toInt32(row_number() OVER (ORDER BY snapshot_id)) AS id,
    snapshot_id,
    'loaded' AS etl_status,
    CAST(NULL, 'Nullable(DateTime64(6))') AS etl_start_time,
    CAST(NULL, 'Nullable(DateTime64(6))') AS etl_end_time,
    CAST(NULL, 'Nullable(String)') AS error,
    CAST(NULL, 'Nullable(Int32)') AS num_failed_parse_vehicle_locations,
    n AS num_successful_parse_vehicle_locations,
    CAST(NULL, 'Nullable(Int32)') AS num_added_siri_rides,
    CAST(NULL, 'Nullable(Int32)') AS num_added_siri_ride_stops,
    CAST(NULL, 'Nullable(Int32)') AS num_added_siri_routes,
    CAST(NULL, 'Nullable(Int32)') AS num_added_siri_stops,
    CAST(NULL, 'Nullable(DateTime64(6))') AS last_heartbeat,
    CAST(NULL, 'Nullable(String)') AS created_by,
    CAST(NULL, 'Nullable(DateTime64(6))') AS etl_pending_time
FROM (
    SELECT siri_snapshot_id AS snapshot_id, toInt32(count()) AS n
    FROM siri_feed
    GROUP BY siri_snapshot_id
) AS fresh
WHERE snapshot_id NOT IN (SELECT snapshot_id FROM siri_snapshot);

-- The ride. See rule 2 above for why scheduled_start_time is an argMin and not
-- a key column. The gtfs_* columns are the output of a separate enrichment that
-- joins rides to the GTFS schedule, and are left NULL here.
CREATE OR REPLACE VIEW enrich_ride_src AS
WITH fresh AS (
    SELECT
        r.id AS siri_route_id,
        v.journey_ref AS journey_ref,
        v.vehicle_ref AS vehicle_ref,
        argMin(v.scheduled_start_time, v.siri_snapshot_id) AS scheduled_start_time
    FROM siri_feed AS v
    INNER JOIN siri_route AS r
        ON r.line_ref = v.line_ref AND r.operator_ref = v.operator_ref
    GROUP BY siri_route_id, journey_ref, vehicle_ref
)
SELECT
    (SELECT ifNull(max(id), 0) FROM siri_ride)
        + toInt32(row_number() OVER (ORDER BY siri_route_id, journey_ref, vehicle_ref)) AS id,
    siri_route_id,
    journey_ref,
    scheduled_start_time,
    vehicle_ref,
    CAST(NULL, 'Nullable(DateTime64(6))') AS updated_first_last_vehicle_locations,
    CAST(NULL, 'Nullable(Int64)') AS first_vehicle_location_id,
    CAST(NULL, 'Nullable(Int64)') AS last_vehicle_location_id,
    CAST(NULL, 'Nullable(DateTime64(6))') AS updated_duration_minutes,
    CAST(NULL, 'Nullable(Int32)') AS duration_minutes,
    CAST(NULL, 'Nullable(Int32)') AS journey_gtfs_ride_id,
    CAST(NULL, 'Nullable(Int32)') AS route_gtfs_ride_id,
    CAST(NULL, 'Nullable(Int32)') AS gtfs_ride_id,
    CAST(NULL, 'Nullable(Int32)') AS scheduled_time_gtfs_ride_id
FROM fresh
-- Unrestricted, `NOT IN` builds a set of all 110M rides: measured at 6.83 GiB,
-- which no ceiling survives. So the right side is restricted to what the batch
-- could possibly collide with, and the column to restrict on is journey_ref,
-- not siri_route_id: a journey_ref carries its own date, so an hour's 19,668 of
-- them matched 0 historical rides, while that same hour's 3,914 routes matched
-- 91,961,186 — 83% of the table, which prunes nothing. The `by_natural_key`
-- projection in db/projections.sql is sorted journey_ref first for this.
WHERE (siri_route_id, journey_ref, vehicle_ref) NOT IN (
    SELECT (siri_route_id, journey_ref, vehicle_ref)
    FROM siri_ride
    WHERE journey_ref IN (SELECT journey_ref FROM fresh)
);

-- A new ride's stops are new by definition, so this needs no lookup against
-- the 2.8-billion-row table — only against the rides it hangs off.
CREATE OR REPLACE VIEW enrich_ride_stop_src AS
WITH fresh AS (
    SELECT DISTINCT
        rd.id AS siri_ride_id,
        s.id AS siri_stop_id,
        v.stop_order AS `order`
    FROM siri_feed AS v
    INNER JOIN siri_route AS r
        ON r.line_ref = v.line_ref AND r.operator_ref = v.operator_ref
    INNER JOIN (SELECT * FROM siri_ride WHERE journey_ref IN (SELECT journey_ref FROM siri_feed)) AS rd
        ON rd.siri_route_id = r.id
       AND rd.journey_ref = v.journey_ref
       AND rd.vehicle_ref = v.vehicle_ref
    INNER JOIN siri_stop AS s ON s.code = v.stop_code
)
SELECT
    (SELECT ifNull(max(id), 0) FROM siri_ride_stop)
        + row_number() OVER (ORDER BY siri_ride_id, `order`, siri_stop_id) AS id,
    siri_stop_id,
    siri_ride_id,
    `order`,
    CAST(NULL, 'Nullable(Int32)') AS gtfs_stop_id,
    CAST(NULL, 'Nullable(Int64)') AS nearest_siri_vehicle_location_id
FROM fresh
-- Same shape, and more necessary: siri_ride_stop is 2.8 billion rows, so the
-- unrestricted set is not merely large but impossible. A new ride's stops are
-- new by definition, so only the rides in this batch have to be looked at, and
-- the `by_siri_ride` projection makes that a seek.
WHERE (siri_ride_id, siri_stop_id, `order`) NOT IN (
    SELECT (siri_ride_id, siri_stop_id, `order`)
    FROM siri_ride_stop
    WHERE siri_ride_id IN (SELECT siri_ride_id FROM fresh)
);

-- The fact table.
--
-- Idempotency here is per snapshot, not per row, and that distinction is the
-- whole point. A row is NOT uniquely identified by
-- (siri_snapshot_id, siri_ride_stop_id, recorded_at_time): production holds 785
-- genuine duplicates on that triple in a single measured hour, so filtering on
-- it would silently drop rows production keeps. A snapshot, on the other hand,
-- is processed exactly once upstream, which is the same granularity
-- `siri_snapshot_seen` already uses for the ingest.
CREATE OR REPLACE VIEW enrich_vehicle_location_src AS
SELECT
    (SELECT ifNull(maxMerge(max_id), 0) FROM siri_vehicle_location_max_id)
        + row_number() OVER (ORDER BY recorded_at_time, siri_ride_stop_id) AS id,
    siri_snapshot_id,
    siri_ride_stop_id,
    recorded_at_time,
    lon,
    lat,
    bearing,
    velocity,
    distance_from_journey_start,
    CAST(NULL, 'Nullable(Int32)') AS distance_from_siri_ride_stop_meters
FROM (
    SELECT
        sn.id AS siri_snapshot_id,
        rs.id AS siri_ride_stop_id,
        v.recorded_at_time AS recorded_at_time,
        v.lon AS lon,
        v.lat AS lat,
        v.bearing AS bearing,
        v.velocity AS velocity,
        v.distance_from_journey_start AS distance_from_journey_start
    FROM siri_feed AS v
    INNER JOIN (
        SELECT id, snapshot_id FROM siri_snapshot
        WHERE snapshot_id IN (SELECT siri_snapshot_id FROM siri_feed)
          AND id NOT IN (SELECT siri_snapshot_id FROM siri_snapshot_enriched FINAL)
    ) AS sn ON sn.snapshot_id = v.siri_snapshot_id
    INNER JOIN siri_route AS r
        ON r.line_ref = v.line_ref AND r.operator_ref = v.operator_ref
    INNER JOIN (SELECT * FROM siri_ride WHERE journey_ref IN (SELECT journey_ref FROM siri_feed)) AS rd
        ON rd.siri_route_id = r.id
       AND rd.journey_ref = v.journey_ref
       AND rd.vehicle_ref = v.vehicle_ref
    INNER JOIN siri_stop AS s ON s.code = v.stop_code
    INNER JOIN (
        SELECT id, siri_ride_id, siri_stop_id, `order` FROM siri_ride_stop
        WHERE siri_ride_id IN (
            SELECT id FROM siri_ride WHERE journey_ref IN (SELECT journey_ref FROM siri_feed)
        )
    ) AS rs
        ON rs.siri_ride_id = rd.id AND rs.siri_stop_id = s.id AND rs.`order` = v.stop_order
) AS fresh;

-- The chain. DEPENDS ON is what orders it: a step refreshes only after the one
-- it reads from has finished, so a ride never looks for a route that is not
-- there yet. APPEND is load-bearing — without it a refreshable view REPLACES
-- its target's contents, which here would delete the history every minute.

CREATE MATERIALIZED VIEW IF NOT EXISTS enrich_route
REFRESH EVERY 1 MINUTE APPEND TO siri_route AS SELECT * FROM enrich_route_src;

CREATE MATERIALIZED VIEW IF NOT EXISTS enrich_stop
REFRESH EVERY 1 MINUTE APPEND TO siri_stop AS SELECT * FROM enrich_stop_src;

CREATE MATERIALIZED VIEW IF NOT EXISTS enrich_snapshot
REFRESH EVERY 1 MINUTE APPEND TO siri_snapshot AS SELECT * FROM enrich_snapshot_src;

CREATE MATERIALIZED VIEW IF NOT EXISTS enrich_ride
REFRESH EVERY 1 MINUTE DEPENDS ON enrich_route
APPEND TO siri_ride AS SELECT * FROM enrich_ride_src;

CREATE MATERIALIZED VIEW IF NOT EXISTS enrich_ride_stop
REFRESH EVERY 1 MINUTE DEPENDS ON enrich_ride, enrich_stop
APPEND TO siri_ride_stop AS SELECT * FROM enrich_ride_stop_src;

CREATE MATERIALIZED VIEW IF NOT EXISTS enrich_vehicle_location
REFRESH EVERY 1 MINUTE DEPENDS ON enrich_ride_stop, enrich_snapshot
APPEND TO siri_vehicle_location AS SELECT * FROM enrich_vehicle_location_src;
