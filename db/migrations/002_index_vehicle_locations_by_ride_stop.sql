-- Lets a lookup by ride skip the locations that cannot belong to it, instead of
-- reading all of them: the table is sorted by time, and a ride's stops have ids
-- issued when the ride is first seen, so the ids rise with the time and a block
-- of locations spans a narrow range of them.
--
-- A minmax index skips only blocks whose range excludes every id asked for, so
-- it never drops a row. It costs two numbers per four granules.
--
-- MATERIALIZE runs as a mutation in the background and reads the one column;
-- the API answers correctly while it runs, and faster once it ends.
ALTER TABLE siri_vehicle_location ADD INDEX IF NOT EXISTS ride_stop_minmax siri_ride_stop_id TYPE minmax GRANULARITY 4;
ALTER TABLE siri_vehicle_location MATERIALIZE INDEX ride_stop_minmax;
