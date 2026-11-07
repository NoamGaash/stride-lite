-- `ingest_day_health` gained four columns, because the three it had could not
-- describe the damage they existed to report.
--
-- `duplicate_ids` counts siri_vehicle_location only, and the worst-damaged
-- table was siri_ride_stop: 9,161,623 duplicate ids and 1,287,638 duplicate
-- natural keys, which no column here could show. Worse, duplicate ids are only
-- one of the race's two failure modes — when two passes read different starting
-- maxima, every id is unique and the same reading is simply stored twice. On
-- 2026-08-16 that read as 15,189,121 rows, 15,189,121 distinct ids and
-- 7,294,846 distinct readings, with `duplicate_ids` reporting 0.
--
-- Existing rows get 0 for the new columns, which is wrong rather than unknown —
-- so every day whose verdict matters is re-measured by ingest/repair-range.sh
-- after a repair, and ReplacingMergeTree(measured_at) keeps the newer answer.
ALTER TABLE stride.ingest_day_health
    ADD COLUMN IF NOT EXISTS snapshots_expected UInt32 AFTER snapshots,
    ADD COLUMN IF NOT EXISTS duplicate_readings UInt64 AFTER duplicate_ids,
    ADD COLUMN IF NOT EXISTS duplicate_ride_ids UInt64 AFTER rides_linked_to_gtfs,
    ADD COLUMN IF NOT EXISTS duplicate_ride_stop_keys UInt64 AFTER duplicate_ride_ids;
