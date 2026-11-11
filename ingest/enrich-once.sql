-- Runs the enrichment once, over whatever is in siri_vehicle_location_raw.
--
-- Same six SELECT bodies as the refreshable chain in ingest/enrich.sql, which
-- defines them as views; this file only decides when they run. Use it after a
-- backfill, or to catch up without waiting for the next refresh.
--
-- Order matters for the same reason DEPENDS ON does in enrich.sql: each step
-- reads the ids the previous one assigned.
--
--   clickhouse client --database stride --multiquery \
--     --param_day=2026-06-02 < ingest/enrich-once.sql

INSERT INTO siri_route SELECT * FROM enrich_route_src;
INSERT INTO siri_stop SELECT * FROM enrich_stop_src;
INSERT INTO siri_snapshot SELECT * FROM enrich_snapshot_src;
INSERT INTO siri_ride SELECT * FROM enrich_ride_src;
INSERT INTO siri_ride_stop SELECT * FROM enrich_ride_stop_src;
INSERT INTO siri_vehicle_location SELECT * FROM enrich_vehicle_location_src;

-- The durations of the day just loaded. Unlike the six above, this one needs to
-- be told which day: see the comment on enrich_duration_src for why the landing
-- table cannot say. The caller passes the day; backfill-range.sh does.
--
-- The window reaches six hours back so a ride that departed before midnight is
-- measured whole, and `settled_before` is the day's own end rather than now():
-- the last six hours of the day are left to the next day's run, which walks
-- over them again. That is why backfill-range.sh goes oldest-first.
INSERT INTO siri_ride_duration
SELECT * FROM enrich_duration_src(
    from = toDateTime({day:Date}) - INTERVAL 6 HOUR,
    to = toDateTime({day:Date}) + INTERVAL 30 HOUR,
    settled_before = toDateTime({day:Date}) + INTERVAL 24 HOUR);

-- The GTFS rides the day's rides ran, from the day before on for the rides
-- whose durations the previous day's run left to this one.
INSERT INTO siri_ride_gtfs
SELECT * FROM enrich_gtfs_link_src(from = {day:Date} - 1, to = {day:Date});

-- What the day turned out to be worth, recorded where the API can serve it.
-- Last, so it measures the rows the steps above just wrote.
INSERT INTO ingest_day_health SELECT * FROM ingest_day_health_src(day = {day:Date});
