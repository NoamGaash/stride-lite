-- Landing tables for one day of the GTFS feed.
--
-- Every column is a String, like the SIRI landing table and for the same
-- reason: the feed is text, and parsing it is the next step's job rather than
-- the loader's. They hold one day at a time and are truncated by ingest/gtfs.sh
-- before each load.
--
-- The feed ships no calendar_dates.txt, so service is decided entirely by
-- calendar.txt's date range and weekday flags. If that ever changes, the
-- `active_services` CTE in ingest/gtfs.sql is where exceptions would go.

CREATE TABLE IF NOT EXISTS gtfs_raw_agency
(agency_id String, agency_name String, agency_url String, agency_timezone String,
 agency_lang String, agency_phone String, agency_fare_url String)
ENGINE = MergeTree ORDER BY agency_id;

CREATE TABLE IF NOT EXISTS gtfs_raw_calendar
(service_id String, sunday String, monday String, tuesday String, wednesday String,
 thursday String, friday String, saturday String, start_date String, end_date String)
ENGINE = MergeTree ORDER BY service_id;

CREATE TABLE IF NOT EXISTS gtfs_raw_routes
(route_id String, agency_id String, route_short_name String, route_long_name String,
 route_desc String, route_type String, route_color String)
ENGINE = MergeTree ORDER BY route_id;

CREATE TABLE IF NOT EXISTS gtfs_raw_stops
(stop_id String, stop_code String, stop_name String, stop_desc String, stop_lat String,
 stop_lon String, location_type String, parent_station String, zone_id String)
ENGINE = MergeTree ORDER BY stop_id;

CREATE TABLE IF NOT EXISTS gtfs_raw_trips
(route_id String, service_id String, trip_id String, trip_headsign String,
 direction_id String, shape_id String, wheelchair_accessible String)
ENGINE = MergeTree ORDER BY trip_id;

CREATE TABLE IF NOT EXISTS gtfs_raw_stop_times
(trip_id String, arrival_time String, departure_time String, stop_id String,
 stop_sequence String, pickup_type String, drop_off_type String, shape_dist_traveled String)
ENGINE = MergeTree ORDER BY (trip_id, stop_sequence);
