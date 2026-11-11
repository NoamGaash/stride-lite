-- Durations for the past, a UTC day per refresh, newest first. Production
-- stopped measuring them in November 2024 (open-bus-stride-etl#22: the job ran
-- out of memory and was switched off) and resumed for recent rides only, so a
-- copy of its data has a hole the hourly enrich_duration never looks back at.
-- A day is taken once the live window has passed it; rides it already measured
-- are skipped by enrich_duration_src itself, so a day with no hole costs one
-- read of its locations. Each day is recorded in backfill_progress once its
-- refresh has run. Applied after ingest/enrich.sql, whose enrich_duration_src
-- it reuses.

CREATE OR REPLACE VIEW duration_history_next_day AS
SELECT maxOrNull(d) AS day
FROM (
    SELECT DISTINCT toDate(replaceAll(substring(snapshot_id, 1, 10), '/', '-')) AS d
    FROM siri_snapshot
)
WHERE d <= (SELECT toDate(replaceAll(substring(max(snapshot_id), 1, 10), '/', '-'))
            FROM siri_snapshot) - 2
  AND d NOT IN (SELECT day FROM backfill_progress WHERE step = 'duration');

CREATE OR REPLACE MATERIALIZED VIEW enrich_duration_history
REFRESH EVERY 2 MINUTE
APPEND TO siri_ride_duration AS
WITH toDateTime(ifNull((SELECT day FROM duration_history_next_day), toDate(0))) AS d
SELECT * FROM enrich_duration_src(
    from = d - INTERVAL 6 HOUR,
    to = d + INTERVAL 30 HOUR,
    settled_before = d + INTERVAL 24 HOUR);

CREATE OR REPLACE MATERIALIZED VIEW enrich_duration_history_done
REFRESH EVERY 2 MINUTE DEPENDS ON enrich_duration_history
APPEND TO backfill_progress AS
SELECT 'duration' AS step, day FROM duration_history_next_day WHERE day IS NOT NULL;
