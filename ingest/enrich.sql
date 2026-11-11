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

CREATE OR REPLACE MATERIALIZED VIEW siri_snapshot_enriched_mv
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

CREATE OR REPLACE MATERIALIZED VIEW siri_vehicle_location_max_id_mv
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
  )
  -- The NOT IN alone does not prune: ClickHouse cannot use that nested set for
  -- the partition key and silently reads every part, which on the node was the
  -- whole landing table (a billion rows) on every step, every minute. A scalar
  -- lower bound is known before index analysis, and the partition key's minmax
  -- then skips every part older than the oldest pending snapshot. Nothing
  -- pending gives a bound above every id, so a no-op refresh reads nothing.
  AND siri_snapshot_id >= (
      SELECT if(count() = 0, '9999', min(siri_snapshot_id))
      FROM siri_snapshot_seen
      WHERE siri_snapshot_id NOT IN (
          SELECT snapshot_id FROM siri_snapshot
          WHERE id IN (SELECT siri_snapshot_id FROM siri_snapshot_enriched FINAL)
      )
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
-- a key column. The gtfs_* columns stay NULL: the match to the GTFS schedule is
-- kept in siri_ride_gtfs, by enrich_gtfs_link_src below.
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

-- The duration of a ride, and the locations at its two ends.
--
-- This is the one step that cannot read the landing table. A ride's duration is
-- a property of all its locations, and those keep arriving for hours after the
-- ride row exists, so the input is siri_vehicle_location and the question is
-- which slice of 6.87 billion rows to read. That slice cannot be derived from
-- the landing table either: during a backfill the landing holds both the day
-- being loaded and the live hour, so its newest snapshot is `now` and says
-- nothing about the day. So the window is a parameter, and the two callers
-- differ only in what they pass.
--
-- The settling rule is upstream's, from add_ride_durations.py: a ride counts as
-- finished when its last location is more than six hours old. What is NOT
-- upstream's is its second pass, which writes duration_minutes = 0 for rides it
-- gave up on — a measurement that was never measured. Here a ride with no
-- settled locations keeps a NULL, which is what "we do not know" looks like.
--
-- `min(recorded_at_time) >= {from}` is the other half of the window: without it
-- a ride that started before the window gets a duration measured from the
-- window's edge, and the dedupe below then freezes that wrong answer forever.
--
-- The API joins this table directly rather than through a view over siri_ride.
-- A view was the first shape tried and it is the wrong one: as a subquery it
-- stops the endpoint's filter reaching the base table, and the same page that
-- costs 0.653 s with the join written inline instead died on the 4 GiB ceiling
-- in FillingRightJoinSide. db/migrations seeds the dump's own measurements into
-- this table so there is one place to read from and no coalescing anywhere.
--
-- The table itself is in db/schema.sql, not here: migrations run before this
-- file on every deploy, and the one that seeds it would find nothing to seed.
-- Ties are the reason the extremes are argMin/argMax over (time, id) and not
-- over time alone. A ride commonly has several readings sharing one
-- recorded_at_time, and production picks among them in scan order: measured
-- against a day in 2024-09, no tie-break reproduces its choice better than a
-- coin flip (48% and 51% for the first id), while the duration itself matches
-- 108,230 of 108,237 rides. So the duration is reproducible and these two ids
-- are not; what the tuple buys is that OUR answer is stable.
CREATE OR REPLACE VIEW enrich_duration_src AS
WITH
    rides AS (
        SELECT
            rs.siri_ride_id AS siri_ride_id,
            vl.id AS id,
            vl.recorded_at_time AS recorded_at_time
        FROM siri_vehicle_location AS vl
        INNER JOIN siri_ride_stop AS rs ON rs.id = vl.siri_ride_stop_id
        WHERE vl.recorded_at_time >= {from:DateTime}
          AND vl.recorded_at_time < {to:DateTime}
    ),
    -- Restricted to the batch for the reason rule 3 gives: unrestricted, this
    -- becomes a set of every ride ever measured. siri_ride_duration is sorted
    -- by siri_ride_id, so the restriction is a primary-key lookup.
    done AS (
        SELECT siri_ride_id
        FROM siri_ride_duration
        WHERE siri_ride_id IN (SELECT siri_ride_id FROM rides)
    )
SELECT
    siri_ride_id,
    argMin(id, (recorded_at_time, id)) AS first_vehicle_location_id,
    argMax(id, (recorded_at_time, id)) AS last_vehicle_location_id,
    toInt32(round((max(recorded_at_time) - min(recorded_at_time)) / 60)) AS duration_minutes
FROM rides
GROUP BY siri_ride_id
HAVING max(recorded_at_time) < {settled_before:DateTime}
   AND min(recorded_at_time) >= {from:DateTime}
   AND siri_ride_id NOT IN done;

-- Durations for the past, a UTC day per refresh, newest first. Production
-- stopped measuring them in November 2024 (open-bus-stride-etl#22: the job ran
-- out of memory and was switched off) and resumed for recent rides only, so a
-- copy of its data has a hole the hourly enrich_duration never looks back at.
-- A day is taken once the live window has passed it; rides it already measured
-- are skipped by enrich_duration_src itself, so a day with no hole costs one
-- read of its locations. Each day is recorded in siri_ride_duration_days once
-- its refresh has run.
CREATE TABLE IF NOT EXISTS siri_ride_duration_days
(
    day Date
)
ENGINE = MergeTree
ORDER BY day;

CREATE OR REPLACE VIEW duration_history_next_day AS
SELECT maxOrNull(d) AS day
FROM (
    SELECT DISTINCT toDate(replaceAll(substring(snapshot_id, 1, 10), '/', '-')) AS d
    FROM siri_snapshot
)
WHERE d <= (SELECT toDate(replaceAll(substring(max(snapshot_id), 1, 10), '/', '-'))
            FROM siri_snapshot) - 2
  AND d NOT IN (SELECT day FROM siri_ride_duration_days);

-- Which GTFS ride each SIRI ride ran, decided as production decides it in
-- open-bus-stride-etl's siri/update_rides_gtfs.py:
--
--   journey_gtfs_ride_id         the GTFS ride whose journey_ref is the SIRI
--                                one rewritten (2025-03-14-17336336 is
--                                17336336_140325), on a GTFS route of the
--                                ride's day.
--   route_gtfs_ride_id           a GTFS ride of the same operator and line, on
--                                the ride's day, starting less than 1, else 3,
--                                else 5 minutes from the SIRI scheduled start.
--   gtfs_ride_id                 the journey match if there is one, else the
--                                route match.
--   scheduled_time_gtfs_ride_id  a GTFS ride of the same operator and line, on
--                                the ride's day or the next, starting exactly
--                                at the SIRI scheduled start.
--
-- "The ride's day" is the UTC date of its scheduled start, because that is what
-- production's date_trunc gives on its UTC database. Where production takes
-- whichever row its UPDATE ... FROM meets first, this takes the nearest start
-- and then the lowest id, so the answer is at least stable. Production also
-- links only a ride whose duration it has measured; this links every ride,
-- because the match reads nothing that changes after the ride is created.
--
-- Written to siri_ride_gtfs, a table of its own like siri_ride_duration,
-- because siri_ride is only ever appended to.
--
-- Rides are taken by the date their journey_ref starts with, which the
-- by_natural_key projection on siri_ride is sorted by; scheduled_start_time has
-- no index. The id bounds turn that into a primary-key range on siri_ride.
CREATE OR REPLACE VIEW enrich_gtfs_link_src AS
WITH
    toString({from:Date}) AS lo,
    toString({to:Date} + 1) AS hi,
    (SELECT (min(id), max(id)) FROM siri_ride WHERE journey_ref >= lo AND journey_ref < hi) AS ids,
    loaded AS (
        SELECT DISTINCT date FROM gtfs_route
        WHERE date BETWEEN {from:Date} - 1 AND {to:Date} + 1
    ),
    rides AS (
        SELECT r.id AS siri_ride_id,
               r.journey_ref AS journey_ref,
               assumeNotNull(r.scheduled_start_time) AS scheduled_start_time,
               toDate(r.scheduled_start_time, 'UTC') AS day,
               sr.operator_ref AS operator_ref,
               sr.line_ref AS line_ref
        FROM siri_ride AS r
        INNER JOIN siri_route AS sr ON sr.id = r.siri_route_id
        WHERE r.id BETWEEN ids.1 AND ids.2
          AND r.journey_ref >= lo AND r.journey_ref < hi
          AND r.scheduled_start_time IS NOT NULL
          AND r.id NOT IN (SELECT siri_ride_id FROM siri_ride_gtfs
                           WHERE siri_ride_id BETWEEN ids.1 AND ids.2)
          AND toDate(r.scheduled_start_time, 'UTC') IN loaded
    ),
    planned AS (
        SELECT g.id AS gtfs_ride_id,
               g.journey_ref AS journey_ref,
               g.start_time AS start_time,
               gr.date AS day,
               gr.operator_ref AS operator_ref,
               gr.line_ref AS line_ref
        FROM gtfs_ride AS g
        INNER JOIN gtfs_route AS gr ON gr.id = g.gtfs_route_id
        WHERE g.gtfs_route_id IN (SELECT id FROM gtfs_route
                                  WHERE date BETWEEN {from:Date} - 1 AND {to:Date} + 2)
    ),
    by_journey AS (
        SELECT r.siri_ride_id AS siri_ride_id, toNullable(min(p.gtfs_ride_id)) AS gtfs_ride_id
        FROM rides AS r
        INNER JOIN planned AS p
            ON p.journey_ref = concat(splitByChar('-', r.journey_ref)[4], '_',
                                      splitByChar('-', r.journey_ref)[3],
                                      splitByChar('-', r.journey_ref)[2],
                                      substring(splitByChar('-', r.journey_ref)[1], 3))
           AND p.day = r.day
        GROUP BY siri_ride_id
    ),
    by_line AS (
        SELECT r.siri_ride_id AS siri_ride_id,
               argMinIfOrNull(p.gtfs_ride_id,
                   (abs(dateDiff('second', p.start_time, r.scheduled_start_time)), p.gtfs_ride_id),
                   p.day = r.day
                   AND abs(dateDiff('second', p.start_time, r.scheduled_start_time)) < 300) AS route_gtfs_ride_id,
               minIfOrNull(p.gtfs_ride_id,
                   p.start_time = r.scheduled_start_time
                   AND p.day BETWEEN r.day AND r.day + 1) AS scheduled_time_gtfs_ride_id
        FROM rides AS r
        INNER JOIN planned AS p
            ON p.operator_ref = r.operator_ref AND p.line_ref = r.line_ref
        GROUP BY siri_ride_id
    )
SELECT r.siri_ride_id AS siri_ride_id,
       toDate(substring(r.journey_ref, 1, 10)) AS journey_date,
       j.gtfs_ride_id AS journey_gtfs_ride_id,
       l.route_gtfs_ride_id AS route_gtfs_ride_id,
       coalesce(j.gtfs_ride_id, l.route_gtfs_ride_id) AS gtfs_ride_id,
       l.scheduled_time_gtfs_ride_id AS scheduled_time_gtfs_ride_id
FROM rides AS r
LEFT JOIN by_journey AS j ON j.siri_ride_id = r.siri_ride_id
LEFT JOIN by_line AS l ON l.siri_ride_id = r.siri_ride_id;

-- The chain. DEPENDS ON is what orders it: a step refreshes only after the one
-- it reads from has finished, so a ride never looks for a route that is not
-- there yet. APPEND is load-bearing — without it a refreshable view REPLACES
-- its target's contents, which here would delete the history every minute.
--
-- Replacing a view this chain depends on keeps the dependency: measured, after
-- OR REPLACE of an upstream view the dependent still declares DEPENDS ON it and
-- both stay Scheduled.

CREATE OR REPLACE MATERIALIZED VIEW enrich_route
REFRESH EVERY 1 MINUTE APPEND TO siri_route AS SELECT * FROM enrich_route_src;

CREATE OR REPLACE MATERIALIZED VIEW enrich_stop
REFRESH EVERY 1 MINUTE APPEND TO siri_stop AS SELECT * FROM enrich_stop_src;

CREATE OR REPLACE MATERIALIZED VIEW enrich_snapshot
REFRESH EVERY 1 MINUTE APPEND TO siri_snapshot AS SELECT * FROM enrich_snapshot_src;

CREATE OR REPLACE MATERIALIZED VIEW enrich_ride
REFRESH EVERY 1 MINUTE DEPENDS ON enrich_route
APPEND TO siri_ride AS SELECT * FROM enrich_ride_src;

CREATE OR REPLACE MATERIALIZED VIEW enrich_ride_stop
REFRESH EVERY 1 MINUTE DEPENDS ON enrich_ride, enrich_stop
APPEND TO siri_ride_stop AS SELECT * FROM enrich_ride_stop_src;

CREATE OR REPLACE MATERIALIZED VIEW enrich_vehicle_location
REFRESH EVERY 1 MINUTE DEPENDS ON enrich_ride_stop, enrich_snapshot
APPEND TO siri_vehicle_location AS SELECT * FROM enrich_vehicle_location_src;

-- Hourly, not every minute: nothing it can act on changes faster than that,
-- because a ride has to be six hours quiet before it counts. The window is a
-- day and a half so that a ride which settles just inside the six-hour bound is
-- still wholly within it.
CREATE OR REPLACE MATERIALIZED VIEW enrich_duration
REFRESH EVERY 1 HOUR DEPENDS ON enrich_vehicle_location
APPEND TO siri_ride_duration AS
SELECT * FROM enrich_duration_src(
    from = now() - INTERVAL 36 HOUR,
    to = now(),
    settled_before = now() - INTERVAL 6 HOUR);

-- One journey date per refresh, newest first, which also walks back through
-- history on its own. A date is taken once it is final:
--
--   * its rides' scheduled starts fall on it or, in UTC, the day before, and a
--     scheduled-time match may sit on the next day's GTFS, so all three days
--     of GTFS are loaded;
--   * every snapshot its rides can appear in has been enriched, which is true
--     once a snapshot two days later has;
--   * SIRI ran that day. A date whose rides all went unmatched still has rows,
--     so this is what keeps the view from choosing an empty date forever.
--
-- A date is done once siri_ride_gtfs holds rows for it. Linking waits for the
-- next day's GTFS, so yesterday's rides are linked the morning after.
CREATE OR REPLACE MATERIALIZED VIEW enrich_gtfs_link
REFRESH EVERY 5 MINUTE
APPEND TO siri_ride_gtfs AS
WITH
    (SELECT groupUniqArray(assumeNotNull(date)) FROM gtfs_route WHERE date IS NOT NULL) AS gtfs,
    (SELECT toDate(replaceAll(substring(max(snapshot_id), 1, 10), '/', '-'))
     FROM siri_snapshot) AS enriched_to,
    (SELECT maxOrNull(d)
     FROM (SELECT DISTINCT toDate(replaceAll(substring(siri_snapshot_id, 1, 10), '/', '-')) AS d
           FROM siri_snapshot_seen)
     WHERE has(gtfs, d - 1) AND has(gtfs, d) AND has(gtfs, d + 1)
       AND d + 2 <= enriched_to
       AND d NOT IN (SELECT DISTINCT journey_date FROM siri_ride_gtfs)) AS next_date
SELECT * FROM enrich_gtfs_link_src(from = ifNull(next_date, toDate(0)), to = ifNull(next_date, toDate(0)));


CREATE OR REPLACE MATERIALIZED VIEW enrich_duration_history
REFRESH EVERY 2 MINUTE
APPEND TO siri_ride_duration AS
WITH toDateTime(ifNull((SELECT day FROM duration_history_next_day), toDate(0))) AS d
SELECT * FROM enrich_duration_src(
    from = d - INTERVAL 6 HOUR,
    to = d + INTERVAL 30 HOUR,
    settled_before = d + INTERVAL 24 HOUR);

CREATE OR REPLACE MATERIALIZED VIEW enrich_duration_history_done
REFRESH EVERY 2 MINUTE DEPENDS ON enrich_duration_history
APPEND TO siri_ride_duration_days AS
SELECT day FROM duration_history_next_day WHERE day IS NOT NULL;
