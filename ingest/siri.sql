-- Continuous SIRI ingest: new snapshots land in ClickHouse by themselves, with
-- no scheduler, no worker and no application code.
--
-- The SELECT body is the org's own dbt macro `ingest_siri_vehicle_location`
-- (open-bus-stride-clickhouse), kept close to it on purpose so the two do not
-- drift. What that macro does not do, and what the org's PLAN.md still lists as
-- open, is the loop:
--
--     [ ] Need to keep track of ingested siri snapshots to avoid re-ingesting
--     [ ] Ingest new snapshots as they arrive from siri requester
--
-- This file is that loop. Three objects.
--
-- Apply with:  clickhouse client --database stride --multiquery < ingest/siri.sql

-- 1. Which snapshots are already in. Derived from the data rather than tracked
--    beside it, so the two cannot disagree and a crash cannot desynchronise
--    them. ~2.2M short strings today.
CREATE TABLE IF NOT EXISTS siri_snapshot_seen
(
    siri_snapshot_id String
)
ENGINE = ReplacingMergeTree
ORDER BY siri_snapshot_id;

-- 2. Maintains it. An incremental view sees each INSERT's own block and writes
--    only that block's ids, so the cost follows new rows and never the billions
--    already stored.
CREATE OR REPLACE MATERIALIZED VIEW siri_snapshot_seen_mv
TO siri_snapshot_seen
AS
SELECT siri_snapshot_id
FROM siri_vehicle_location_raw
GROUP BY siri_snapshot_id;

-- 3. The loop itself, as two views over the same body.
--
--    APPEND is load-bearing: a refreshable view without it REPLACES its
--    target's contents on every refresh, which on an append-only archive would
--    delete all history once a minute.
--
--    Two views and not one because the hour is a glob and S3 has no "last two
--    hours" pattern (a brace alternation across `/` does not work — it was
--    measured and it hangs). `current` picks up each new minute inside the
--    running hour; `previous` closes the hour boundary and heals any gap left by
--    a missed refresh or a restart. Both are idempotent, so overlap is free:
--    the WHERE clause makes a redundant pass read 60 file headers and write 0
--    rows.

CREATE OR REPLACE MATERIALIZED VIEW siri_ingest_current
REFRESH EVERY 1 MINUTE APPEND
TO siri_vehicle_location_raw
AS
SELECT
    replaceRegexpOne(_path, '^[^/]+/stride-siri-requester/(.*)\\.br$', '\\1') AS siri_snapshot_id,
    parseDateTime32BestEffort(MonitoredStopVisit.RecordedAtTime) AS recorded_at_time,
    MonitoredStopVisit.MonitoredVehicleJourney.LineRef AS line_ref,
    MonitoredStopVisit.MonitoredVehicleJourney.FramedVehicleJourneyRef.DataFrameRef AS data_frame_ref,
    MonitoredStopVisit.MonitoredVehicleJourney.FramedVehicleJourneyRef.DatedVehicleJourneyRef AS dated_vehicle_journey_ref,
    MonitoredStopVisit.MonitoredVehicleJourney.OperatorRef AS operator_ref,
    parseDateTime32BestEffort(MonitoredStopVisit.MonitoredVehicleJourney.OriginAimedDepartureTime) AS origin_aimed_departure_time,
    MonitoredStopVisit.MonitoredVehicleJourney.VehicleLocation.Longitude AS vehicle_location_longitude,
    MonitoredStopVisit.MonitoredVehicleJourney.VehicleLocation.Latitude AS vehicle_location_latitude,
    MonitoredStopVisit.MonitoredVehicleJourney.Bearing AS bearing,
    MonitoredStopVisit.MonitoredVehicleJourney.Velocity AS velocity,
    MonitoredStopVisit.MonitoredVehicleJourney.VehicleRef AS vehicle_ref,
    MonitoredStopVisit.MonitoredVehicleJourney.MonitoredCall.StopPointRef AS stop_point_ref,
    MonitoredStopVisit.MonitoredVehicleJourney.MonitoredCall.Order AS stop_order,
    MonitoredStopVisit.MonitoredVehicleJourney.MonitoredCall.DistanceFromStop AS distance_from_stop
FROM s3(
    (SELECT concat('https://openbus-stride-public.s3.eu-west-1.amazonaws.com/stride-siri-requester/', formatDateTime(now(), '%Y/%m/%d/%H'), '/*.br')),
    NOSIGN, JSONEachRow,
    'Siri Tuple(ServiceDelivery Tuple(ResponseTimestamp String, StopMonitoringDelivery Array(Tuple(MonitoredStopVisit Array(Tuple(RecordedAtTime String, MonitoredVehicleJourney Tuple(LineRef String, FramedVehicleJourneyRef Tuple(DataFrameRef String, DatedVehicleJourneyRef String), OperatorRef String, OriginAimedDepartureTime String, VehicleLocation Tuple(Longitude String, Latitude String), Bearing String, Velocity String, VehicleRef String, MonitoredCall Tuple(StopPointRef String, Order String, DistanceFromStop String))))))))'
)
ARRAY JOIN Siri.ServiceDelivery.StopMonitoringDelivery AS StopMonitoringDelivery
ARRAY JOIN StopMonitoringDelivery.MonitoredStopVisit AS MonitoredStopVisit
WHERE replaceRegexpOne(_path, '^[^/]+/stride-siri-requester/(.*)\\.br$', '\\1')
      NOT IN (SELECT siri_snapshot_id FROM siri_snapshot_seen FINAL)
SETTINGS input_format_skip_unknown_fields = 1, glob_expansion_max_elements = 9999999
;

CREATE OR REPLACE MATERIALIZED VIEW siri_ingest_previous
REFRESH EVERY 10 MINUTE APPEND
TO siri_vehicle_location_raw
AS
SELECT
    replaceRegexpOne(_path, '^[^/]+/stride-siri-requester/(.*)\\.br$', '\\1') AS siri_snapshot_id,
    parseDateTime32BestEffort(MonitoredStopVisit.RecordedAtTime) AS recorded_at_time,
    MonitoredStopVisit.MonitoredVehicleJourney.LineRef AS line_ref,
    MonitoredStopVisit.MonitoredVehicleJourney.FramedVehicleJourneyRef.DataFrameRef AS data_frame_ref,
    MonitoredStopVisit.MonitoredVehicleJourney.FramedVehicleJourneyRef.DatedVehicleJourneyRef AS dated_vehicle_journey_ref,
    MonitoredStopVisit.MonitoredVehicleJourney.OperatorRef AS operator_ref,
    parseDateTime32BestEffort(MonitoredStopVisit.MonitoredVehicleJourney.OriginAimedDepartureTime) AS origin_aimed_departure_time,
    MonitoredStopVisit.MonitoredVehicleJourney.VehicleLocation.Longitude AS vehicle_location_longitude,
    MonitoredStopVisit.MonitoredVehicleJourney.VehicleLocation.Latitude AS vehicle_location_latitude,
    MonitoredStopVisit.MonitoredVehicleJourney.Bearing AS bearing,
    MonitoredStopVisit.MonitoredVehicleJourney.Velocity AS velocity,
    MonitoredStopVisit.MonitoredVehicleJourney.VehicleRef AS vehicle_ref,
    MonitoredStopVisit.MonitoredVehicleJourney.MonitoredCall.StopPointRef AS stop_point_ref,
    MonitoredStopVisit.MonitoredVehicleJourney.MonitoredCall.Order AS stop_order,
    MonitoredStopVisit.MonitoredVehicleJourney.MonitoredCall.DistanceFromStop AS distance_from_stop
FROM s3(
    (SELECT concat('https://openbus-stride-public.s3.eu-west-1.amazonaws.com/stride-siri-requester/', formatDateTime(now() - toIntervalHour(1), '%Y/%m/%d/%H'), '/*.br')),
    NOSIGN, JSONEachRow,
    'Siri Tuple(ServiceDelivery Tuple(ResponseTimestamp String, StopMonitoringDelivery Array(Tuple(MonitoredStopVisit Array(Tuple(RecordedAtTime String, MonitoredVehicleJourney Tuple(LineRef String, FramedVehicleJourneyRef Tuple(DataFrameRef String, DatedVehicleJourneyRef String), OperatorRef String, OriginAimedDepartureTime String, VehicleLocation Tuple(Longitude String, Latitude String), Bearing String, Velocity String, VehicleRef String, MonitoredCall Tuple(StopPointRef String, Order String, DistanceFromStop String))))))))'
)
ARRAY JOIN Siri.ServiceDelivery.StopMonitoringDelivery AS StopMonitoringDelivery
ARRAY JOIN StopMonitoringDelivery.MonitoredStopVisit AS MonitoredStopVisit
WHERE replaceRegexpOne(_path, '^[^/]+/stride-siri-requester/(.*)\\.br$', '\\1')
      NOT IN (SELECT siri_snapshot_id FROM siri_snapshot_seen FINAL)
SETTINGS input_format_skip_unknown_fields = 1, glob_expansion_max_elements = 9999999
;
