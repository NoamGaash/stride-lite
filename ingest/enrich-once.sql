-- Runs the enrichment once, over whatever is in siri_vehicle_location_raw.
--
-- Same six SELECT bodies as the refreshable chain in ingest/enrich.sql, which
-- defines them as views; this file only decides when they run. Use it after a
-- backfill, or to catch up without waiting for the next refresh.
--
-- Order matters for the same reason DEPENDS ON does in enrich.sql: each step
-- reads the ids the previous one assigned.
--
--   clickhouse client --database stride --multiquery < ingest/enrich-once.sql

INSERT INTO siri_route SELECT * FROM enrich_route_src;
INSERT INTO siri_stop SELECT * FROM enrich_stop_src;
INSERT INTO siri_snapshot SELECT * FROM enrich_snapshot_src;
INSERT INTO siri_ride SELECT * FROM enrich_ride_src;
INSERT INTO siri_ride_stop SELECT * FROM enrich_ride_stop_src;
INSERT INTO siri_vehicle_location SELECT * FROM enrich_vehicle_location_src;
