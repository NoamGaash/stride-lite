/**
 * The one endpoint that is ours rather than upstream's, and it exists to be
 * public: a reader should be able to see whether the data is current without an
 * account, and an operator should not need one either.
 *
 * It carries nothing about anyone. That is a deliberate exclusion, not a
 * coincidence — ClickHouse's `system.query_log` holds each query's client
 * address, so an "open logs" endpoint built the obvious way would publish
 * visitors' IP addresses. This reads the ingest watermark and the scheduler's
 * own table and nothing else.
 */

/** Everything the response promises, in order. */
export const STATUS_FIELDS = [
  'newest_snapshot',
  'vehicle_locations',
  'newest_gtfs_date',
  'refresh_tasks',
  'refresh_tasks_failing',
] as const

/**
 * Freshness is the newest snapshot id and **not** `max(recorded_at_time)`.
 * The latter is the ministry's own value, 0.32% of it is in the future, and it
 * answers 2038-01-14 — see finding 14. A snapshot id comes from the archive's
 * S3 path, which no vehicle has an opinion about. Bounding the column instead
 * works but was measured at 5.9 s against 105 ms, because the bound stops the
 * index being read from its tail.
 */
export function statusSql(db: string): string {
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(db)) {
    throw new Error(`not a database identifier: ${db}`)
  }
  return `SELECT
    (SELECT max(siri_snapshot_id) FROM ${db}.siri_snapshot_seen FINAL) AS newest_snapshot,
    (SELECT count() FROM ${db}.siri_vehicle_location) AS vehicle_locations,
    (SELECT max(date) FROM ${db}.gtfs_route) AS newest_gtfs_date,
    (SELECT count() FROM system.view_refreshes WHERE database = '${db}') AS refresh_tasks,
    (SELECT count() FROM system.view_refreshes
      WHERE database = '${db}' AND exception != '') AS refresh_tasks_failing`
}
