import { describe, it, expect } from 'vitest'
import { COVERAGE_FIELDS, STATUS_FIELDS, coverageSql, statusSql } from '../src/status'

describe('the public status query', () => {
  it('reports every field the endpoint promises', () => {
    const sql = statusSql('stride')
    for (const field of STATUS_FIELDS) expect(sql).toContain(`AS ${field}`)
  })

  it('reads the database it is given, and system tables by name', () => {
    expect(statusSql('prod')).toContain('prod.siri_snapshot_seen')
    expect(statusSql('prod')).toContain("database = 'prod'")
    expect(statusSql('prod')).toContain('system.view_refreshes')
  })

  /**
   * The reason this endpoint exists rather than `max(recorded_at_time)`: that
   * column is the ministry's own value and 0.32% of it is in the future, so it
   * answers 2038. See finding 14. The watermark comes from the archive's S3
   * path instead, which no bus has an opinion about.
   */
  it('does not take its freshness from a column the feed controls', () => {
    expect(statusSql('stride')).not.toContain('recorded_at_time')
  })

  it('refuses a database name that is not an identifier', () => {
    expect(() => statusSql("stride'; DROP DATABASE stride --")).toThrow()
    expect(() => statusSql('has-a-dash')).toThrow()
  })
})

describe('the per-day coverage query', () => {
  it('selects every field the endpoint promises', () => {
    const sql = coverageSql('stride', 30)
    for (const field of COVERAGE_FIELDS) expect(sql).toContain(field)
  })

  /**
   * The four columns that were added after a repair passed the old gate. A day
   * is unsound in ways `duplicate_ids` cannot express: it counts
   * siri_vehicle_location alone, and it counts only the failure mode where two
   * passes share a starting max. 2026-08-16 had 0 duplicate ids and every
   * reading stored twice.
   */
  it('reports the damage that duplicate_ids alone cannot describe', () => {
    for (const field of [
      'duplicate_readings',
      'duplicate_ride_ids',
      'duplicate_ride_stop_keys',
      'snapshots_expected',
    ]) {
      expect(COVERAGE_FIELDS as readonly string[]).toContain(field)
    }
  })

  /**
   * FINAL is load-bearing and not a flourish: ingest_day_health is a
   * ReplacingMergeTree keyed on the day, so a repaired day carries two verdicts
   * and the endpoint must serve the newer one. Without it /coverage keeps
   * reporting damage that has been fixed.
   */
  it('reads the newest verdict for a day, not the first', () => {
    expect(coverageSql('stride', 30)).toContain('FINAL')
  })

  it('refuses a limit or a database name it cannot vouch for', () => {
    expect(() => coverageSql('stride', 0)).toThrow()
    expect(() => coverageSql('stride', 10001)).toThrow()
    expect(() => coverageSql('has-a-dash', 30)).toThrow()
  })
})
