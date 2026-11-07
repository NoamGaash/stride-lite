-- Is the fact table self-consistent over a date range?
--
-- The ingest mints `id` as `max(id) + row_number()`, so it is only a key if one
-- enrichment pass runs at a time. Two overlapping passes read the same starting
-- max and mint the same numbers: the same source row lands twice under one id,
-- and worse, two different readings land under one id. Both happened here
-- (2026-06-15, 2026-08-16) when the hourly refreshable view overlapped a
-- backfill, so this is a gate and not a diagnostic.
--
-- Only duplicates are an error. Row counts per day are reported and never
-- asserted: Friday is about half a weekday and Saturday about a sixth, so a
-- threshold on them would cry wolf once a week. A human reads the column.
--
-- Usage:
--   clickhouse client -d prod --param_from=2026-06-01 --param_to=2026-06-30 \
--     --queries-file ingest/verify.sql

SELECT
    toDate(recorded_at_time) AS day,
    dateName('weekday', toDate(recorded_at_time)) AS weekday,
    count() AS rows,
    uniqExact(id) AS distinct_ids,
    count() - uniqExact(id) AS duplicate_rows
FROM siri_vehicle_location
WHERE recorded_at_time >= toDateTime({from:Date})
  AND recorded_at_time < toDateTime({to:Date}) + INTERVAL 1 DAY
GROUP BY day
ORDER BY day;

-- The gate. Throws if any id in the range covers more than one row, which is
-- what makes this runnable from a script that checks an exit code. The counts
-- are selected alongside rather than built into the message, because throwIf
-- takes only a constant there.
SELECT
    sum(extra) AS extra_rows,
    count() AS duplicated_ids,
    throwIf(sum(extra) > 0, 'duplicate ids in siri_vehicle_location') AS ok
FROM (
    SELECT count() - 1 AS extra
    FROM siri_vehicle_location
    WHERE recorded_at_time >= toDateTime({from:Date})
      AND recorded_at_time < toDateTime({to:Date}) + INTERVAL 1 DAY
    GROUP BY id
    HAVING count() > 1
);
