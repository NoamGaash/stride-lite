-- What the API reads that the dump does not contain.
--
-- `gtfs_rides_agg_by_hour` is a PostgreSQL materialized view upstream, defined
-- in open-bus-stride-db migration e277ec8f5a04 and rebuilt by the
-- stride-etl-gtfs-update-ride-aggregations DAG. Here it is a table rebuilt by a
-- refreshable view, which is the same arrangement without the DAG.
--
-- It is NOT a plain view. Measured: as a view it joins 115M gtfs_ride rows to
-- 110M siri_ride rows per request and dies on a 4 GiB ceiling, because
-- ClickHouse hashes a join's right side whole. Materialised it is 53,006,384
-- rows in 181 MiB and rebuilds in 37 s.
--
-- Two details of upstream's definition that the rewrite has to keep:
--
--   * `count(*)` counts the rows a LEFT JOIN emits, so a gtfs_ride matched by
--     several siri_rides is counted several times. Measured: 51,283,120 siri
--     rides map to 50,728,935 distinct gtfs rides, so this is not hypothetical,
--     and `sum(greatest(n, 1))` is what reproduces it.
--   * `num_actual_rides` counts only the matched rows, which is `sum(n)`.
--
-- Applied by scripts/apply-schema.sh.

CREATE TABLE IF NOT EXISTS gtfs_rides_agg_by_hour
(
    gtfs_route_id Int32,
    gtfs_route_hour DateTime,
    gtfs_route_date DateTime,
    num_planned_rides UInt64,
    num_actual_rides UInt64
)
ENGINE = MergeTree
ORDER BY (gtfs_route_date, gtfs_route_id, gtfs_route_hour);

-- No APPEND here, unlike the ingest and enrichment views: this one is an
-- aggregate of everything, so each refresh should replace the table rather than
-- add to it. `REFRESH EVERY 6 HOUR` matches how often GTFS itself changes,
-- which is daily.
--
-- OR REPLACE and not IF NOT EXISTS, here and in ingest/: measured, a changed
-- body under IF NOT EXISTS is accepted and silently discarded, so the file and
-- the database drift with nothing to say so. Replacing triggers one immediate
-- refresh, which for this view is the same full rebuild it does every 6 hours
-- and for the APPEND views is a pass their NOT IN makes free.
--
-- `full_sorting_merge` rather than the default hash: both sides are large, and
-- the hash build is exactly what exceeded the memory ceiling.
CREATE OR REPLACE MATERIALIZED VIEW gtfs_rides_agg_by_hour_refresh
REFRESH EVERY 6 HOUR
TO gtfs_rides_agg_by_hour
AS
SELECT gtfs_route_id, gtfs_route_hour, gtfs_route_date,
       sum(greatest(n, 1)) AS num_planned_rides,
       sum(n) AS num_actual_rides
FROM (
    SELECT gr.gtfs_route_id AS gtfs_route_id,
           toStartOfHour(gr.start_time) AS gtfs_route_hour,
           toStartOfDay(gr.start_time) AS gtfs_route_date,
           ifNull(s.n, 0) AS n
    FROM gtfs_ride AS gr
    LEFT JOIN (
        SELECT scheduled_time_gtfs_ride_id AS rid, count() AS n
        FROM siri_ride_gtfs FINAL
        WHERE scheduled_time_gtfs_ride_id IS NOT NULL
        GROUP BY rid
    ) AS s ON gr.id = s.rid
)
GROUP BY gtfs_route_id, gtfs_route_hour, gtfs_route_date
SETTINGS join_algorithm = 'full_sorting_merge',
         max_bytes_before_external_sort = 600000000,
         max_bytes_before_external_group_by = 600000000,
         max_bytes_in_join = 0;
