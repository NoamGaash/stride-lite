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

-- The chain must be off. This is the first statement for the reason the file
-- exists at all: running these INSERTs while ingest/enrich.sql's refreshable
-- views are enabled is the bug that damaged twenty-nine days. Both paths mint
-- `id` as max(id) + row_number(), so both read the same starting max and hand
-- the same numbers to different readings.
--
-- backfill-range.sh and repair-range.sh stop the chain before calling this, so
-- for them the check always passes. It is here for the caller that does not:
-- a person at a terminal, which is how it happened. Measured: with the chain
-- Scheduled this throws, and the six INSERTs below never run.
--
-- A refresh already in flight when the views were stopped is NOT covered here —
-- SYSTEM STOP VIEW prevents the next refresh and does not cancel the running
-- one. chain-guard.sh waits that out; this only refuses the obvious mistake.
SELECT throwIf(
    count() > 0,
    'the enrichment chain is enabled: SYSTEM STOP VIEW it first, or use ingest/backfill-range.sh'
) FROM system.view_refreshes
WHERE database = currentDatabase() AND startsWith(view, 'enrich_') AND status != 'Disabled';

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

-- What the day turned out to be worth, recorded where the API can serve it.
-- Last, so it measures the rows the six steps above just wrote.
INSERT INTO ingest_day_health SELECT * FROM ingest_day_health_src(day = {day:Date});
