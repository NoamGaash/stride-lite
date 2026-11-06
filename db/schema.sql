CREATE TABLE stride.alembic_version
(
    `version_num` String
)
ENGINE = MergeTree
ORDER BY tuple()
SETTINGS index_granularity = 8192
;

CREATE TABLE stride.artifact
(
    `id` Int32,
    `file_prefix` Nullable(String),
    `status` LowCardinality(String),
    `metadata_json` Nullable(String),
    `error` Nullable(String),
    `url` Nullable(String),
    `created_at` Nullable(DateTime64(6)),
    `file_size_bytes` Nullable(Int32)
)
ENGINE = MergeTree
ORDER BY id
SETTINGS index_granularity = 8192
;

CREATE TABLE stride.clustertoline
(
    `operatorname` Nullable(String),
    `officelineid` Nullable(Int32),
    `operatorlineid` Nullable(Int32),
    `clustername` Nullable(String),
    `fromdate` Nullable(String),
    `todate` Nullable(String),
    `clusterid` Nullable(Int32),
    `linetype` Nullable(Int32),
    `linetypedesc` Nullable(String),
    `clustersubdesc` Nullable(String)
)
ENGINE = MergeTree
ORDER BY tuple()
SETTINGS index_granularity = 8192
;

CREATE TABLE stride.gtfs_data
(
    `id` Int32,
    `date` Nullable(Date32),
    `processing_started_at` Nullable(DateTime64(6)),
    `processing_completed_at` Nullable(DateTime64(6)),
    `processing_error` Nullable(String),
    `processing_success` LowCardinality(String),
    `processing_used_stride_date` Nullable(Date32),
    `download_upload_started_at` Nullable(DateTime64(6)),
    `download_upload_completed_at` Nullable(DateTime64(6)),
    `download_upload_error` Nullable(String),
    `download_upload_success` LowCardinality(String)
)
ENGINE = MergeTree
ORDER BY id
SETTINGS index_granularity = 8192
;

CREATE TABLE stride.gtfs_data_task
(
    `id` Int32,
    `gtfs_data_id` Nullable(Int32),
    `task_name` Nullable(String),
    `started_at` Nullable(DateTime64(6)),
    `completed_at` Nullable(DateTime64(6)),
    `error` Nullable(String),
    `success` LowCardinality(String)
)
ENGINE = MergeTree
ORDER BY id
SETTINGS index_granularity = 8192
;

CREATE TABLE stride.gtfs_ride
(
    `id` Int32,
    `gtfs_route_id` Nullable(Int32),
    `journey_ref` Nullable(String),
    `first_gtfs_ride_stop_id` Nullable(Int64),
    `last_gtfs_ride_stop_id` Nullable(Int64),
    `start_time` Nullable(DateTime),
    `end_time` Nullable(DateTime)
)
ENGINE = MergeTree
ORDER BY id
SETTINGS index_granularity = 8192
;

CREATE TABLE stride.gtfs_ride_stop
(
    `id` Int64,
    `gtfs_stop_id` Nullable(Int32),
    `gtfs_ride_id` Nullable(Int32),
    `stop_sequence` Nullable(Int32),
    `pickup_type` Nullable(Int32),
    `drop_off_type` Nullable(Int32),
    `shape_dist_traveled` Nullable(Int32),
    `arrival_time` Nullable(DateTime),
    `departure_time` Nullable(DateTime),
    INDEX idx_tight gtfs_ride_id TYPE bloom_filter(0.0001) GRANULARITY 1,
    PROJECTION by_ride
    (
        SELECT
            id,
            gtfs_stop_id,
            gtfs_ride_id,
            stop_sequence,
            pickup_type,
            drop_off_type,
            shape_dist_traveled,
            arrival_time,
            departure_time
        ORDER BY
            gtfs_ride_id,
            gtfs_stop_id
    )
)
ENGINE = MergeTree
ORDER BY id
SETTINGS index_granularity = 8192
;

CREATE TABLE stride.gtfs_route
(
    `id` Int32,
    `date` Nullable(Date32),
    `line_ref` Nullable(Int32),
    `operator_ref` Nullable(Int32),
    `route_short_name` Nullable(String),
    `route_long_name` Nullable(String),
    `route_mkt` Nullable(String),
    `route_direction` Nullable(String),
    `route_alternative` Nullable(String),
    `agency_name` Nullable(String),
    `route_type` Nullable(String)
)
ENGINE = MergeTree
ORDER BY id
SETTINGS index_granularity = 8192
;

CREATE TABLE stride.gtfs_stop
(
    `id` Int32,
    `date` Nullable(Date32),
    `code` Nullable(Int32),
    `lat` Nullable(Float64),
    `lon` Nullable(Float64),
    `name` Nullable(String),
    `city` Nullable(String)
)
ENGINE = MergeTree
ORDER BY id
SETTINGS index_granularity = 8192
;

CREATE TABLE stride.gtfs_stop_mot_id
(
    `id` Int32,
    `gtfs_stop_id` Nullable(Int32),
    `mot_id` Nullable(Int32)
)
ENGINE = MergeTree
ORDER BY id
SETTINGS index_granularity = 8192
;

-- Measured from the locations of a finished ride, by ingest/enrich.sql. Not a
-- production table: there the same three values are columns of siri_ride, and
-- an UPDATE is how they get there. ClickHouse has no equivalent -- a mutation
-- cannot read a per-row value from another table -- so they are a table, and
-- siri_ride's own copies are left to the dump that filled them.
CREATE TABLE stride.siri_ride_duration
(
    `siri_ride_id` Int32,
    `first_vehicle_location_id` Int64,
    `last_vehicle_location_id` Int64,
    `duration_minutes` Int32
)
ENGINE = MergeTree
ORDER BY siri_ride_id
;

CREATE TABLE stride.siri_ride
(
    `id` Int32,
    `siri_route_id` Nullable(Int32),
    `journey_ref` Nullable(String),
    `scheduled_start_time` Nullable(DateTime),
    `vehicle_ref` Nullable(String),
    `updated_first_last_vehicle_locations` Nullable(DateTime64(6)),
    `first_vehicle_location_id` Nullable(Int64),
    `last_vehicle_location_id` Nullable(Int64),
    `updated_duration_minutes` Nullable(DateTime64(6)),
    `duration_minutes` Nullable(Int32),
    `journey_gtfs_ride_id` Nullable(Int32),
    `route_gtfs_ride_id` Nullable(Int32),
    `gtfs_ride_id` Nullable(Int32),
    `scheduled_time_gtfs_ride_id` Nullable(Int32)
)
ENGINE = MergeTree
ORDER BY id
SETTINGS index_granularity = 8192
;

CREATE TABLE stride.siri_ride_stop
(
    `id` Int64,
    `siri_stop_id` Nullable(Int32),
    `siri_ride_id` Nullable(Int32),
    `order` Nullable(Int32),
    `gtfs_stop_id` Nullable(Int32),
    `nearest_siri_vehicle_location_id` Nullable(Int64)
)
ENGINE = MergeTree
ORDER BY id
SETTINGS index_granularity = 8192
;

CREATE TABLE stride.siri_route
(
    `id` Int32,
    `line_ref` Nullable(Int32),
    `operator_ref` Nullable(Int32)
)
ENGINE = MergeTree
ORDER BY id
SETTINGS index_granularity = 8192
;

CREATE TABLE stride.siri_snapshot
(
    `id` Int32,
    `snapshot_id` Nullable(String),
    `etl_status` LowCardinality(String),
    `etl_start_time` Nullable(DateTime64(6)),
    `etl_end_time` Nullable(DateTime64(6)),
    `error` Nullable(String),
    `num_failed_parse_vehicle_locations` Nullable(Int32),
    `num_successful_parse_vehicle_locations` Nullable(Int32),
    `num_added_siri_rides` Nullable(Int32),
    `num_added_siri_ride_stops` Nullable(Int32),
    `num_added_siri_routes` Nullable(Int32),
    `num_added_siri_stops` Nullable(Int32),
    `last_heartbeat` Nullable(DateTime64(6)),
    `created_by` Nullable(String),
    `etl_pending_time` Nullable(DateTime64(6))
)
ENGINE = MergeTree
ORDER BY id
SETTINGS index_granularity = 8192
;

CREATE TABLE stride.siri_stop
(
    `id` Int32,
    `code` Nullable(Int32)
)
ENGINE = MergeTree
ORDER BY id
SETTINGS index_granularity = 8192
;

CREATE TABLE stride.siri_vehicle_location
(
    `id` Int64,
    `siri_snapshot_id` Nullable(Int32),
    `siri_ride_stop_id` Nullable(Int64),
    `recorded_at_time` DateTime,
    `lon` Nullable(Float64),
    `lat` Nullable(Float64),
    `bearing` Nullable(Int32),
    `velocity` Nullable(Int32),
    `distance_from_journey_start` Nullable(Int32),
    `distance_from_siri_ride_stop_meters` Nullable(Int32),
    INDEX id_minmax id TYPE minmax GRANULARITY 4
)
ENGINE = MergeTree
ORDER BY (recorded_at_time, id)
SETTINGS index_granularity = 8192
;

