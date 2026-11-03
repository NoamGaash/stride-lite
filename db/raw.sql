-- The raw SIRI landing table, written by ingest/siri.sql.
--
-- This is deliberately NOT the same table as `siri_vehicle_location` in
-- db/schema.sql. The two have different jobs and different shapes:
--
--   siri_vehicle_location_raw  what the MOT feed actually contains: every field
--                              a string, one row per MonitoredStopVisit, no
--                              foreign keys. This is the org's ClickHouse
--                              schema (open-bus-stride-clickhouse) verbatim.
--
--   siri_vehicle_location      what the API serves: typed, numeric, and joined
--                              to siri_ride_stop / siri_snapshot by integer id.
--
-- Deriving the second from the first is the enrichment, and it is the piece
-- that is NOT built yet — see ROADMAP.md. Today the API's tables come from the
-- public dump and the raw table comes from S3; nothing joins them.

CREATE TABLE IF NOT EXISTS siri_vehicle_location_raw
(
    siri_snapshot_id String,
    recorded_at_time DateTime,
    line_ref String,
    data_frame_ref String,
    dated_vehicle_journey_ref String,
    operator_ref String,
    origin_aimed_departure_time DateTime,
    vehicle_location_longitude String,
    vehicle_location_latitude String,
    bearing String,
    velocity String,
    vehicle_ref String,
    stop_point_ref String,
    stop_order String,
    distance_from_stop String
)
ENGINE = MergeTree
PARTITION BY format('{0}/{1}', splitByChar('/', siri_snapshot_id)[1], splitByChar('/', siri_snapshot_id)[2])
PRIMARY KEY (recorded_at_time);
