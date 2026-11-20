-- The node's own load and memory, one reading a minute for a week, so
-- /ops/metrics can say how loaded the node has been and not only how loaded it
-- is now. ClickHouse's asynchronous_metric_log would keep this too, but it is
-- off in this server's config and writes hundreds of metrics a second.
--
-- Applied by scripts/apply-schema.sh.

CREATE TABLE IF NOT EXISTS node_metrics
(
    measured_at DateTime,
    load1 Float32,
    memory_total UInt64,
    memory_available UInt64
)
ENGINE = MergeTree
ORDER BY measured_at
TTL measured_at + INTERVAL 8 DAY;

CREATE OR REPLACE MATERIALIZED VIEW node_metrics_refresh
REFRESH EVERY 1 MINUTE APPEND
TO node_metrics
AS
SELECT now() AS measured_at,
       toFloat32(anyIf(value, metric = 'LoadAverage1')) AS load1,
       toUInt64(anyIf(value, metric = 'OSMemoryTotal')) AS memory_total,
       toUInt64(anyIf(value, metric = 'OSMemoryAvailable')) AS memory_available
FROM system.asynchronous_metrics
WHERE metric IN ('LoadAverage1', 'OSMemoryTotal', 'OSMemoryAvailable');
