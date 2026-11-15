import { Params } from '../src/ch'
import { rawEndpoints } from '../src/raw'
import { readFileSync } from 'node:fs'
import { describe, it, expect } from 'vitest'
import { endpoints } from '../src/registry'
import { buildQuery, UnknownOrderField } from '../src/sql'

/** column name -> type, per table, read from the schema the node applies. */
function schemaColumns(): Map<string, Map<string, string>> {
  const sql = readFileSync(new URL('../../db/schema.sql', import.meta.url), 'utf8')
  const tables = new Map<string, Map<string, string>>()
  for (const m of sql.matchAll(/CREATE TABLE (\S+)\s*\(([\s\S]*?)\n\)/g)) {
    const cols = new Map<string, string>()
    for (const c of m[2].matchAll(/^\s*`(\w+)` (.+?),?$/gm)) cols.set(c[1], c[2])
    tables.set(m[1], cols)
  }
  return tables
}

const ordered = endpoints.filter((e) => e.orderByDefault !== undefined && !e.skipOrderBy)
const tables = schemaColumns()

// Production resolves order_by with getattr on the endpoint's model, so any of
// the base table's own columns can be ordered by, not just the ones a caller
// happened to use first.
describe.each(ordered.map((e) => [e.path, e] as const))('%s order_by', (_path, def) => {
  const columns = tables.get(def.table.replace(/^[^.]+\./, 'stride.'))
  const own = def.fields.filter((f) => columns?.has(f))

  // Other guards, like gtfs_ride_stops' required arrival window, are not what
  // this is about, so only the order_by rejection counts.
  it.each(own)('accepts %s', (field) => {
    let error: unknown
    try {
      buildQuery(def, new URLSearchParams({ order_by: `${field} asc` }))
    } catch (e) {
      error = e
    }
    expect(error).not.toBeInstanceOf(UnknownOrderField)
  })

  // A byte order differs from production's glibc collation on Hebrew text.
  it.each(own.filter((f) => /String/.test(columns!.get(f)!)))('sorts text column %s as production does', (field) => {
    expect(def.textOrder ?? []).toContain(field)
  })
})

/**
 * siri_vehicle_location is sorted by time. A filter on a joined table leaves
 * it unbounded, so it is read whole: 127 GiB, past CloudFront's 90 s.
 */
describe('a ride filter on /siri_vehicle_locations/list', () => {
  const def = endpoints.find((e) => e.path === '/siri_vehicle_locations/list')!

  it('also narrows the locations themselves, through their ride stops', () => {
    const { sql } = buildQuery(def, new URLSearchParams({ siri_rides__ids: '153697999,153697748' }))
    expect(sql).toContain(
      'vl.siri_ride_stop_id IN (SELECT id FROM stride.siri_ride_stop WHERE siri_ride_id IN (153697999, 153697748))',
    )
  })

  it('which the index on the locations can use', () => {
    const sql = readFileSync(new URL('../../db/schema.sql', import.meta.url), 'utf8')
    expect(sql).toMatch(/INDEX \w+ siri_ride_stop_id TYPE minmax/)
  })
})

/**
 * Upstream bounds the route table by date_from on both sides, so a range past
 * 31 days drops every later day without a word: hasadna/open-bus-stride-api#70.
 */
describe('the ride aggregates over a range longer than a month', () => {
  it.each(['/gtfs_rides_agg/group_by', '/gtfs_rides_agg/list'])('%s reads routes up to date_to', (path) => {
    const def = rawEndpoints.find((e) => e.path === path)!
    const bound = new Params()
    const sql = def.build(
      new URLSearchParams('date_from=2023-05-01&date_to=2023-06-29&group_by=gtfs_route_date'),
      'stride',
      bound,
    )
    const upper = /rt\.date <= \{(\w+):Date\}/.exec(sql)![1]
    expect(bound.values[upper]).toBe('2023-07-29')
  })
})
