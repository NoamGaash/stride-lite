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

/** Everything /coverage promises, in order. */
export const COVERAGE_FIELDS = [
  'day',
  'snapshots',
  'snapshots_expected',
  'vehicle_locations',
  'duplicate_ids',
  'duplicate_readings',
  'rides',
  'rides_with_duration',
  'rides_linked_to_gtfs',
  'duplicate_ride_ids',
  'duplicate_ride_stop_keys',
  'measured_at',
] as const

/**
 * Per-day data health, read from the table ingest/health.sql maintains rather
 * than computed per request: `duplicate_ids` is a uniqExact over a day's rows,
 * which is a nightly cost and not a per-request one.
 *
 * It answers the question production cannot. Finding 13 is twenty months of
 * "zero buses ran" that reads as data rather than as an outage, because
 * `/gtfs_rides_agg/group_by` returns 0 either way. Here a day states how many
 * snapshots arrived, how many rows were derived from them, and whether its ids
 * are sound — so "nothing ran", "nothing arrived" and "we broke it" are three
 * different rows and not one.
 *
 * `duplicate_ids` is siri_vehicle_location's alone, which is why the two
 * `duplicate_ride_*` columns name their own table: a reader could not otherwise
 * tell the scope, and the worst of the damage this endpoint exists to report
 * was in siri_ride_stop. `duplicate_readings` is the one that catches the
 * failure the id columns cannot see at all — the same reading stored twice
 * under two different ids. It is never zero on a healthy day either: about 785
 * duplicate readings an hour are legitimate upstream, so the judgement is a
 * ratio against `vehicle_locations` and ingest/verify.sql puts it at 1.01.
 *
 * `snapshots_expected` is a ceiling and not a floor. 1440 is one snapshot a
 * minute; a healthy day lands about 1,430, and 2026-08-19 holds 455 because the
 * archive itself holds 455. A shortfall is not by itself our failure.
 *
 * Newest first, because the question is almost always about recent data, and
 * FINAL because the table is a ReplacingMergeTree keyed on the day: a repaired
 * day is re-measured, and the old verdict must not outrank the new one.
 */
export function coverageSql(db: string, limit: number): string {
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(db)) {
    throw new Error(`not a database identifier: ${db}`)
  }
  if (!Number.isInteger(limit) || limit < 1 || limit > 10000) {
    throw new Error(`not a usable limit: ${limit}`)
  }
  return `SELECT ${COVERAGE_FIELDS.join(', ')}
    FROM ${db}.ingest_day_health FINAL
    ORDER BY day DESC
    LIMIT ${limit}`
}
