-- Derive one day of the API's GTFS tables from the landing tables.
--
-- Driven by ingest/gtfs.sh, which passes the date as {date:Date}. Idempotent:
-- a date already loaded is skipped, because every step filters on
-- `gtfs_route.date` and the first step inserts nothing when rows exist.
--
-- This is open-bus-gtfs-etl's three loaders plus stride-etl's
-- update_ride_aggregations, expressed as SQL. The mappings are theirs, not
-- invented here, and the ones that are easy to get wrong:
--
--   * `route_desc` is "mkt-direction-alternative", split on '-' into exactly
--     three parts; anything else leaves all three NULL.
--   * `stop_desc` holds the city between the literals 'עיר:' and 'רציף:'.
--   * GTFS times run past 24:00:00 to mean "after midnight", and they are
--     LOCAL Israel times. Both matter: the hours roll into the next calendar
--     day and the result is then converted from Asia/Jerusalem, which is 23 or
--     25 hours long twice a year.
--   * A stop is identified by `stop_code`, not by `stop_id`. Several stop_ids
--     can share a code, and gtfs_stop_mot_id is what records them all.
--   * A ride's start_time is its first stop's DEPARTURE and its end_time is
--     its last stop's ARRIVAL, ordered by stop_sequence.
--
-- The feed is pruned to the date the way partridge prunes it: trips whose
-- service runs that day, then only the routes and stops those trips reach.

-- Which trips run on this date. A table rather than a view: a view holding
-- {date:Date} is a parameterised view, which has different call syntax, and a
-- view that reads another view inside IN is rejected as correlated. One table
-- of 100k-odd rows avoids both and is read many times below.
--
-- No calendar_dates.txt in this feed, so the weekday flag and the date range
-- are the whole rule. ClickHouse counts Monday as 1; the feed starts at Sunday.
CREATE TABLE IF NOT EXISTS gtfs_active_trip
(trip_id String, route_id String)
ENGINE = MergeTree ORDER BY trip_id;

TRUNCATE TABLE gtfs_active_trip;

INSERT INTO gtfs_active_trip
SELECT t.trip_id, t.route_id
FROM gtfs_raw_trips AS t
INNER JOIN gtfs_raw_calendar AS c ON c.service_id = t.service_id
WHERE toDate(parseDateTimeBestEffort(c.start_date)) <= {date:Date}
  AND toDate(parseDateTimeBestEffort(c.end_date)) >= {date:Date}
  AND multiIf(
        toDayOfWeek({date:Date}) = 7, c.sunday,
        toDayOfWeek({date:Date}) = 1, c.monday,
        toDayOfWeek({date:Date}) = 2, c.tuesday,
        toDayOfWeek({date:Date}) = 3, c.wednesday,
        toDayOfWeek({date:Date}) = 4, c.thursday,
        toDayOfWeek({date:Date}) = 5, c.friday,
        c.saturday) = '1';

-- 1. Routes. Only those an active trip reaches.
INSERT INTO gtfs_route
SELECT
    (SELECT ifNull(max(id), 0) FROM gtfs_route) + toInt32(row_number() OVER (ORDER BY line_ref)) AS id,
    {date:Date} AS date,
    line_ref,
    operator_ref,
    route_short_name,
    route_long_name,
    route_mkt,
    route_direction,
    route_alternative,
    agency_name,
    route_type
FROM (
    SELECT
        toInt32(r.route_id) AS line_ref,
        toInt32(r.agency_id) AS operator_ref,
        -- An empty field reaches production through pandas as a float NaN and is
        -- stored as the literal string 'NaN'. 596 of 6,423 routes on 2026-05-20.
        if(r.route_short_name = '', 'NaN', r.route_short_name) AS route_short_name,
        if(r.route_long_name = '', 'NaN', r.route_long_name) AS route_long_name,
        if(length(splitByChar('-', r.route_desc)) = 3, splitByChar('-', r.route_desc)[1], NULL) AS route_mkt,
        if(length(splitByChar('-', r.route_desc)) = 3, splitByChar('-', r.route_desc)[2], NULL) AS route_direction,
        if(length(splitByChar('-', r.route_desc)) = 3, splitByChar('-', r.route_desc)[3], NULL) AS route_alternative,
        a.agency_name AS agency_name,
        r.route_type AS route_type
    FROM gtfs_raw_routes AS r
    LEFT JOIN gtfs_raw_agency AS a ON a.agency_id = r.agency_id
    WHERE r.route_id IN (SELECT route_id FROM gtfs_active_trip)
) AS fresh
WHERE (SELECT count() FROM gtfs_route WHERE date = {date:Date}) = 0;

-- 2. Stops: one row per active stop_id, NOT per stop_code.
--
--    That looks wrong and is what production does. open-bus-gtfs-etl's
--    load_stops_to_db keys its cache by stop_code but never puts a
--    newly-created stop into that cache, so the second feed row carrying the
--    same code misses and inserts again. Measured on 2026-05-20: 30,417 active
--    stop_ids resolve to 29,866 codes, and production holds exactly 30,417
--    rows — the duplicates are the difference, five identical rows for stop
--    code 2463 among them.
--
--    Reproduced rather than corrected, because this is what the API returns
--    today and a migration that quietly changes row counts is not a migration.
--    It is written up in docs/FINDINGS.md as a bug to fix deliberately.
--
--    The stage table carries the stop_id alongside the id it was given, which
--    is what lets the next two steps join on stop_id rather than on code.
--    Joining on code would multiply: six feed rows share code 2463 and six
--    gtfs_stop rows now carry it.
CREATE TABLE IF NOT EXISTS gtfs_stage_stop
(gtfs_stop_id Int32, stop_id Int32, code Int32, lat Float64, lon Float64,
 name String, city Nullable(String))
ENGINE = MergeTree ORDER BY stop_id;

TRUNCATE TABLE gtfs_stage_stop;

INSERT INTO gtfs_stage_stop
SELECT
    (SELECT ifNull(max(id), 0) FROM gtfs_stop) + toInt32(row_number() OVER (ORDER BY stop_id)) AS gtfs_stop_id,
    stop_id, code, lat, lon, name, city
FROM (
    SELECT
        toInt32(stop_id) AS stop_id,
        toInt32(stop_code) AS code,
        toFloat64(stop_lat) AS lat,
        toFloat64(stop_lon) AS lon,
        stop_name AS name,
        nullIf(trim(BOTH ' ' FROM splitByString('רציף:', splitByString('עיר:', stop_desc)[2])[1]), '') AS city
    FROM gtfs_raw_stops
    WHERE stop_id IN (
        SELECT stop_id FROM gtfs_raw_stop_times
        WHERE trip_id IN (SELECT trip_id FROM gtfs_active_trip)
    )
) AS active;

INSERT INTO gtfs_stop
SELECT gtfs_stop_id AS id, {date:Date} AS date, code, lat, lon, name, city
FROM gtfs_stage_stop
WHERE (SELECT count() FROM gtfs_stop WHERE date = {date:Date}) = 0;

-- 3. One mot_id per stop, one-to-one, which follows from step 2.
INSERT INTO gtfs_stop_mot_id
SELECT
    (SELECT ifNull(max(id), 0) FROM gtfs_stop_mot_id) + toInt32(row_number() OVER (ORDER BY gtfs_stop_id)) AS id,
    gtfs_stop_id,
    stop_id AS mot_id
FROM gtfs_stage_stop
WHERE (SELECT count() FROM gtfs_stop_mot_id WHERE gtfs_stop_id IN
        (SELECT id FROM gtfs_stop WHERE date = {date:Date})) = 0;

-- 4. The stop times, with their ids minted up front.
--
--    Minting here rather than on insert is what breaks the circle: a ride
--    needs its first and last stop's id, and a stop needs its ride's id. Both
--    id sets are a function of the staged data alone, so both can be decided
--    before either table is written, and neither needs a mutation afterwards.
CREATE TABLE IF NOT EXISTS gtfs_stage_ride_stop
(
    id Int64, trip_id String, route_id String, stop_sequence Int32, gtfs_stop_id Int32,
    arrival_time DateTime, departure_time DateTime, pickup_type Int32, drop_off_type Int32,
    shape_dist_traveled Nullable(Int32)
)
ENGINE = MergeTree ORDER BY (trip_id, stop_sequence);

TRUNCATE TABLE gtfs_stage_ride_stop;

INSERT INTO gtfs_stage_ride_stop
SELECT
    (SELECT ifNull(max(id), 0) FROM gtfs_ride_stop) + row_number() OVER (ORDER BY trip_id, stop_sequence) AS id,
    trip_id, route_id, stop_sequence, gtfs_stop_id,
    arrival_time, departure_time, pickup_type, drop_off_type, shape_dist_traveled
FROM (
    SELECT
        st.trip_id AS trip_id,
        t.route_id AS route_id,
        toInt32(st.stop_sequence) AS stop_sequence,
        m.gtfs_stop_id AS gtfs_stop_id,
        -- "25:10:00" means 01:10 the next day, in Israel local time.
        toDateTime(
            concat(
                toString({date:Date} + intDiv(toInt32(splitByChar(':', st.arrival_time)[1]), 24)), ' ',
                leftPad(toString(toInt32(splitByChar(':', st.arrival_time)[1]) % 24), 2, '0'), ':',
                splitByChar(':', st.arrival_time)[2], ':', splitByChar(':', st.arrival_time)[3]),
            'Asia/Jerusalem') AS arrival_time,
        toDateTime(
            concat(
                toString({date:Date} + intDiv(toInt32(splitByChar(':', st.departure_time)[1]), 24)), ' ',
                leftPad(toString(toInt32(splitByChar(':', st.departure_time)[1]) % 24), 2, '0'), ':',
                splitByChar(':', st.departure_time)[2], ':', splitByChar(':', st.departure_time)[3]),
            'Asia/Jerusalem') AS departure_time,
        toInt32(st.pickup_type) AS pickup_type,
        toInt32(st.drop_off_type) AS drop_off_type,
        -- Upstream guards with `if not value or isnan(value)`, and `not 0.0` is
        -- true in Python, so a distance of zero is stored as NULL rather than 0.
        -- 6,827 of 242,921 compared rows on 2026-05-20, and the only field of
        -- gtfs_ride_stop that differed before this.
        nullIf(toInt32OrNull(st.shape_dist_traveled), 0) AS shape_dist_traveled
    FROM gtfs_raw_stop_times AS st
    INNER JOIN gtfs_active_trip AS t ON t.trip_id = st.trip_id
    INNER JOIN gtfs_stage_stop AS m ON m.stop_id = toInt32(st.stop_id)
) AS parsed;

-- 5. The rides, which can now name their first and last stop.
INSERT INTO gtfs_ride
SELECT
    (SELECT ifNull(max(id), 0) FROM gtfs_ride) + toInt32(row_number() OVER (ORDER BY journey_ref)) AS id,
    gtfs_route_id,
    journey_ref,
    first_gtfs_ride_stop_id,
    last_gtfs_ride_stop_id,
    start_time,
    end_time
FROM (
    SELECT
        rs.trip_id AS journey_ref,
        any(r.id) AS gtfs_route_id,
        argMin(rs.id, rs.stop_sequence) AS first_gtfs_ride_stop_id,
        argMax(rs.id, rs.stop_sequence) AS last_gtfs_ride_stop_id,
        argMin(rs.departure_time, rs.stop_sequence) AS start_time,
        argMax(rs.arrival_time, rs.stop_sequence) AS end_time
    FROM gtfs_stage_ride_stop AS rs
    INNER JOIN gtfs_route AS r ON r.line_ref = toInt32(rs.route_id) AND r.date = {date:Date}
    GROUP BY journey_ref
) AS fresh
WHERE (SELECT count() FROM gtfs_ride WHERE gtfs_route_id IN
        (SELECT id FROM gtfs_route WHERE date = {date:Date})) = 0;

-- 6. And the stop times themselves, under the ids minted in step 4.
INSERT INTO gtfs_ride_stop
SELECT
    rs.id AS id,
    rs.gtfs_stop_id AS gtfs_stop_id,
    rd.id AS gtfs_ride_id,
    rs.stop_sequence AS stop_sequence,
    rs.pickup_type AS pickup_type,
    rs.drop_off_type AS drop_off_type,
    rs.shape_dist_traveled AS shape_dist_traveled,
    rs.arrival_time AS arrival_time,
    rs.departure_time AS departure_time
FROM gtfs_stage_ride_stop AS rs
INNER JOIN (
    SELECT id, journey_ref FROM gtfs_ride
    WHERE gtfs_route_id IN (SELECT id FROM gtfs_route WHERE date = {date:Date})
) AS rd ON rd.journey_ref = rs.trip_id
WHERE rs.id > (
    SELECT ifNull(max(id), 0) FROM gtfs_ride_stop
    WHERE gtfs_ride_id IN (
        SELECT id FROM gtfs_ride WHERE gtfs_route_id IN
            (SELECT id FROM gtfs_route WHERE date = {date:Date})
    )
);
