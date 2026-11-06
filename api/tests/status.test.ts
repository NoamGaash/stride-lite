import { describe, it, expect } from 'vitest'
import { STATUS_FIELDS, statusSql } from '../src/status'

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
