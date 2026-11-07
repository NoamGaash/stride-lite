-- Runs the six enrichment steps once, over whatever is in
-- siri_vehicle_location_raw and not yet marked enriched.
--
-- Same six SELECT bodies as the refreshable chain in ingest/enrich.sql, which
-- defines them as views; this file only decides when they run. Use it after a
-- backfill, or to catch up without waiting for the next refresh.
--
-- Order matters for the same reason DEPENDS ON does in enrich.sql: each step
-- reads the ids the previous one assigned.
--
-- It takes NO day, and that is the point of the split from enrich-day.sql.
-- `siri_feed` is "everything in landing that is not yet enriched", with no date
-- filter of its own, so what this pass covers is decided entirely by which
-- siri_snapshot_enriched marks the caller has cleared. One pass over seven
-- days' worth of cleared marks costs what one pass over one day costs, because
-- the expense is re-reading the landing table rather than the rows produced:
-- measured, one pass reads 617,028,034 rows and 12.62 GiB, which is 4.1 scans
-- of the 150,966,451 rows landing now holds. Paying that per day is what made a
-- 23-day repair a nine-hour job.
--
--   clickhouse client --database stride --multiquery < ingest/enrich-once.sql

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
