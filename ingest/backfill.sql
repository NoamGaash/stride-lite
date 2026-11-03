-- Backfill a past range of SIRI snapshots. Driven by ingest/backfill.sh, which
-- substitutes __GLOB__ with a Y/M/D or Y/M/D/H path.
--
-- Identical to the SELECT in ingest/siri.sql except that the glob is given
-- rather than derived from now(), so the same dedup filter makes it re-runnable.

INSERT INTO siri_vehicle_location_raw
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
    'https://openbus-stride-public.s3.eu-west-1.amazonaws.com/stride-siri-requester/__GLOB__/*.br',
    NOSIGN, JSONEachRow,
    'Siri Tuple(ServiceDelivery Tuple(ResponseTimestamp String, StopMonitoringDelivery Array(Tuple(MonitoredStopVisit Array(Tuple(RecordedAtTime String, MonitoredVehicleJourney Tuple(LineRef String, FramedVehicleJourneyRef Tuple(DataFrameRef String, DatedVehicleJourneyRef String), OperatorRef String, OriginAimedDepartureTime String, VehicleLocation Tuple(Longitude String, Latitude String), Bearing String, Velocity String, VehicleRef String, MonitoredCall Tuple(StopPointRef String, Order String, DistanceFromStop String))))))))'
)
ARRAY JOIN Siri.ServiceDelivery.StopMonitoringDelivery AS StopMonitoringDelivery
ARRAY JOIN StopMonitoringDelivery.MonitoredStopVisit AS MonitoredStopVisit
WHERE replaceRegexpOne(_path, '^[^/]+/stride-siri-requester/(.*)\\.br$', '\\1')
      NOT IN (SELECT siri_snapshot_id FROM siri_snapshot_seen FINAL)
SETTINGS input_format_skip_unknown_fields = 1, glob_expansion_max_elements = 9999999
;
