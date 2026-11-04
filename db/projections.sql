-- Second sort orders, for the columns the API filters by but the tables are not
-- sorted by. ClickHouse has no secondary index that does this job: a
-- `bloom_filter` on an uncorrelated foreign key was measured at 1.22 s against
-- a projection's 0.015 s, because the correlation of `id` to `gtfs_ride_id` is
-- −0.05 and every granule therefore holds 8192 distinct values.
--
-- They are not free. Measured on the full dump:
--
--   base tables                            163.98 GiB
--   gtfs_ride_stop.by_ride                  29.88 GiB
--   siri_ride_stop.by_gtfs_stop             19.33 GiB
--   siri_ride_stop.by_siri_ride             18.95 GiB
--   siri_ride.by_natural_key                 0.87 GiB
--   ------------------------------------------------
--   total                                  233.02 GiB
--
-- by_gtfs_stop is the one you can leave out: it serves only /stop_arrivals/list,
-- which cannot return a row from production for any input. See docs/FINDINGS.md.
--
-- Building them is I/O bound: about 25 minutes each under the local 40 MB/s
-- write cap in ingest/local.xml, and far less on an unthrottled disk.
--
--   clickhouse client --database stride --multiquery < db/projections.sql
--
-- MATERIALIZE is what fills them for rows already stored; without it a
-- projection only covers parts written after it was declared.

-- /siri_ride_stops/list filters by siri_ride_id, /stop_arrivals/list by
-- gtfs_stop_id, and the table is sorted by neither. Both lookups went from 44 s
-- to 0.016 s.
ALTER TABLE siri_ride_stop ADD PROJECTION IF NOT EXISTS by_siri_ride
(SELECT id, siri_stop_id, siri_ride_id, `order`, gtfs_stop_id, nearest_siri_vehicle_location_id
 ORDER BY siri_ride_id);

ALTER TABLE siri_ride_stop ADD PROJECTION IF NOT EXISTS by_gtfs_stop
(SELECT id, siri_stop_id, siri_ride_id, `order`, gtfs_stop_id, nearest_siri_vehicle_location_id
 ORDER BY gtfs_stop_id);

-- The enrichment asks "which of these rides already exist" every refresh.
-- Without this the answer is a set built from all 110M rides, measured at
-- 6.83 GiB, which no ceiling survives.
-- journey_ref leads the sort order on purpose: it carries its own date, so a
-- batch's journey_refs match almost nothing in history, while its route ids
-- match most of the table.
ALTER TABLE siri_ride ADD PROJECTION IF NOT EXISTS by_natural_key
(SELECT id, siri_route_id, journey_ref, vehicle_ref
 ORDER BY (journey_ref, siri_route_id, vehicle_ref));

-- Join by a foreign key the table is not sorted by: 4.35 s to 0.015 s, reading
-- 3 granules of 328,980.
ALTER TABLE gtfs_ride_stop ADD PROJECTION IF NOT EXISTS by_ride
(SELECT * ORDER BY gtfs_ride_id);

ALTER TABLE siri_ride_stop MATERIALIZE PROJECTION by_siri_ride;
ALTER TABLE siri_ride_stop MATERIALIZE PROJECTION by_gtfs_stop;
ALTER TABLE siri_ride MATERIALIZE PROJECTION by_natural_key;
ALTER TABLE gtfs_ride_stop MATERIALIZE PROJECTION by_ride;
