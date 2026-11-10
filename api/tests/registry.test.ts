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
