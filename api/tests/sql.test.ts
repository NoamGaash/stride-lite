import { describe, it, expect } from 'vitest'
import {
  buildQuery,
  BadRequest,
  TzRequired,
  UnknownOrderField,
  DEFAULT_LIMIT,
  type EndpointDef,
} from '../src/sql'

const routes: EndpointDef = {
  path: '/siri_routes/list',
  model: 'SiriRoute',
  table: 'stride.siri_route',
  alias: 'r',
  fields: ['id', 'line_ref', 'operator_ref'],
  filters: [
    { param: 'line_refs', column: 'r.line_ref', type: 'in' },
    { param: 'name', column: 'r.name', type: 'equals', text: true },
    { param: 'from', column: 'r.recorded_at_time', type: 'datetime_from' },
    { param: 'to', column: 'r.recorded_at_time', type: 'datetime_to' },
    { param: 'lat_ge', column: 'r.lat', type: 'greater_or_equal' },
    { param: 'prefix', column: 'r.code', type: 'prefix', text: true },
    { param: 'day_from', column: 'r.date', type: 'date_from' },
    { param: 'day_to', column: 'r.date', type: 'date_to' },
  ],
  orderable: { id: 'r.id', line_ref: 'r.line_ref' },
  orderByDefault: 'id asc',
}

/** Same shape, but declaring no `order_by` parameter — like /gtfs_stops/list. */
const unordered: EndpointDef = { ...routes, orderByDefault: undefined }

/** Upstream `skip_order_by` — like /route_timetable/list. */
const unsorted: EndpointDef = { ...routes, skipOrderBy: true }

/** The SQL with each bound value written back where it is bound, to read the way ClickHouse binds it. */
const q = (params: Record<string, string>) => {
  const { sql, params: bound } = buildQuery(routes, new URLSearchParams(params))
  return sql.replace(/\{(p\d+):[^}]+\}/g, (_, name: string) => `'${String(bound[name])}'`)
}

describe('limits', () => {
  it('defaults to the upstream default limit', () => {
    expect(q({})).toContain(`LIMIT ${DEFAULT_LIMIT}`)
  })

  it('rejects a limit above the upstream maximum', () => {
    expect(() => q({ limit: '15001' })).toThrow(BadRequest)
  })

  it('rejects a non-positive limit', () => {
    expect(() => q({ limit: '0' })).toThrow(BadRequest)
    expect(() => q({ limit: '-1' })).toThrow(BadRequest)
  })

  it('adds OFFSET only when non-zero', () => {
    expect(q({ offset: '0' })).not.toContain('OFFSET')
    expect(q({ offset: '25' })).toContain('OFFSET 25')
  })
})

describe('ordering', () => {
  // Which default applies is decided by the handler's declaration, not by the
  // request, so each of the three shapes needs its own case.
  it('falls back to the declared default when the caller sends no order_by', () => {
    expect(q({})).toContain('ORDER BY r.id ASC')
  })

  it('orders by id DESC when the endpoint declares no order_by parameter', () => {
    const sql = buildQuery(unordered, new URLSearchParams()).sql
    expect(sql).toContain('ORDER BY r.id DESC')
  })

  it('ignores an order_by sent to an endpoint that declares no such parameter', () => {
    const sql = buildQuery(unordered, new URLSearchParams({ order_by: 'line_ref asc' })).sql
    expect(sql).toContain('ORDER BY r.id DESC')
    expect(sql).not.toContain('ORDER BY r.line_ref')
  })

  it('emits no ORDER BY when the endpoint skips ordering entirely', () => {
    expect(buildQuery(unsorted, new URLSearchParams()).sql).not.toContain('ORDER BY')
  })

  it('treats an empty declared default as no fields, so the tiebreaker orders', () => {
    const sql = buildQuery({ ...routes, orderByDefault: '' }, new URLSearchParams()).sql
    expect(sql).toContain('ORDER BY r.id DESC')
  })

  it('orders a text field by its collation key, then the full string, then id', () => {
    const sql = buildQuery(
      { ...routes, fields: [...routes.fields, 'name'], textOrder: ['name'] },
      new URLSearchParams({ order_by: 'name desc' }),
    ).sql
    expect(sql).toContain(
      "ORDER BY replaceRegexpAll(r.name, '[^\\pL\\pN]', '') DESC COLLATE 'he', r.name DESC COLLATE 'he', r.id DESC",
    )
  })

  it('appends id DESC as a tiebreaker when ordering by another field', () => {
    expect(q({ order_by: 'line_ref asc' })).toContain('ORDER BY r.line_ref ASC, r.id DESC')
  })

  it('does not append a tiebreaker when the caller already orders by id', () => {
    expect(q({ order_by: 'id asc' })).toContain('ORDER BY r.id ASC')
    expect(q({ order_by: 'id asc' })).not.toContain('r.id DESC')
  })

  it('treats any direction other than desc as ascending', () => {
    expect(q({ order_by: 'line_ref' })).toContain('r.line_ref ASC')
    expect(q({ order_by: 'line_ref sideways' })).toContain('r.line_ref ASC')
  })

  // Production answers 500 here, not 422: `getattr(db_model, field_name)`
  // raises AttributeError, which also rules out ordering by a related field.
  it('refuses an unknown order field the way production does', () => {
    expect(() => q({ order_by: 'nope asc' })).toThrow(UnknownOrderField)
    expect(() => q({ order_by: 'nope asc' })).toThrow(
      "type object 'SiriRoute' has no attribute 'nope'",
    )
  })
})

describe('filters', () => {
  it('splits a list filter on commas', () => {
    expect(q({ line_refs: '1,2,3' })).toContain('r.line_ref IN (1, 2, 3)')
  })

  it('ignores empty entries in a list filter', () => {
    expect(q({ line_refs: '1,,2' })).toContain('r.line_ref IN (1, 2)')
  })

  it('drops a list filter that is entirely empty', () => {
    expect(q({ line_refs: ',,' })).not.toContain('WHERE')
  })

  it('caps a list filter at the upstream maximum of 1000', () => {
    const many = Array.from({ length: 1001 }, (_, i) => i).join(',')
    expect(() => q({ line_refs: many })).toThrow(BadRequest)
  })

  it('binds a text value rather than writing it into the SQL', () => {
    const { sql, params } = buildQuery(routes, new URLSearchParams({ name: "O'Brien" }))
    expect(sql).toContain('r.name = {p0:String}')
    expect(sql).not.toContain('Brien')
    expect(params).toEqual({ p0: "O'Brien" })
  })

  it('rejects a non-numeric value for a numeric filter', () => {
    expect(() => q({ lat_ge: 'abc' })).toThrow(BadRequest)
  })

  it('builds a prefix filter as a LIKE', () => {
    expect(q({ prefix: 'abc' })).toContain("r.code LIKE 'abc%'")
  })

  it('omits a filter whose parameter is absent or blank', () => {
    expect(q({ name: '' })).not.toContain('WHERE')
  })
})

describe('date-time parameters', () => {
  // Verified against production: a `from` of 08:00+03:00 returns the same rows
  // as 05:00+00:00 and different rows from 08:00+00:00, so the offset is
  // converted. An offset-less value comes back as a 500, not a 422.
  it('converts the offset to UTC', () => {
    expect(q({ from: '2026-05-20T08:00:00+03:00' })).toContain(
      "r.recorded_at_time >= '2026-05-20 05:00:00'",
    )
  })

  it('treats Z as UTC', () => {
    expect(q({ from: '2026-05-20T08:00:00Z' })).toContain(
      "r.recorded_at_time >= '2026-05-20 08:00:00'",
    )
  })

  it('handles an offset that crosses a day boundary', () => {
    expect(q({ from: '2026-05-20T01:30:00+03:00' })).toContain(
      "r.recorded_at_time >= '2026-05-19 22:30:00'",
    )
  })

  it('accepts an offset without a colon, and a negative one', () => {
    expect(q({ from: '2026-05-20T08:00:00-0430' })).toContain(
      "r.recorded_at_time >= '2026-05-20 12:30:00'",
    )
  })

  // `Date.toISOString()` always writes a fraction, so this is what every call
  // from the frontend looks like. A literal with one is a TYPE_MISMATCH against
  // a second-granular DateTime column, which production answers with rows.
  it('drops a zero fraction, which is what the frontend sends', () => {
    expect(q({ from: '2026-05-20T08:00:00.000Z' })).toContain(
      "r.recorded_at_time >= '2026-05-20 08:00:00'",
    )
  })

  // Exact over whole seconds: a row at 08:00:00 is not >= 08:00:00.5, and is
  // <= 08:00:00.5.
  it('rounds a lower bound up to the next whole second', () => {
    expect(q({ from: '2026-05-20T08:00:00.5+03:00' })).toContain(
      "r.recorded_at_time >= '2026-05-20 05:00:01'",
    )
  })

  it('rounds an upper bound down', () => {
    expect(q({ to: '2026-05-20T08:00:00.5+03:00' })).toContain(
      "r.recorded_at_time <= '2026-05-20 05:00:00'",
    )
  })

  it('carries a rounded-up lower bound across a minute boundary', () => {
    expect(q({ from: '2026-05-20T08:00:59.001Z' })).toContain(
      "r.recorded_at_time >= '2026-05-20 08:01:00'",
    )
  })

  it('defaults a missing seconds field to zero', () => {
    expect(q({ from: '2026-05-20T08:00Z' })).toContain(
      "r.recorded_at_time >= '2026-05-20 08:00:00'",
    )
  })

  it('demands an offset, the way SQLAlchemy does', () => {
    expect(() => q({ from: '2026-05-20T08:00:00' })).toThrow(TzRequired)
  })

  // Production answers 422 "invalid datetime format" here, not the 500 that an
  // offset-less timestamp gets: a date-only string never reaches SQLAlchemy.
  it('rejects a bare date as a bad request rather than a missing offset', () => {
    expect(() => q({ from: '2026-05-20' })).toThrow(BadRequest)
    expect(() => q({ from: '2026-05-20' })).not.toThrow(TzRequired)
  })

  it('rejects an unparseable value as a bad request', () => {
    expect(() => q({ from: 'yesterday' })).toThrow(BadRequest)
  })
})

describe('date parameters', () => {
  // A `format: date` parameter is a calendar day. Rendering it as a timestamp
  // is what made ClickHouse reject the comparison against a Date32 column.
  it('renders a calendar day as a plain date', () => {
    expect(q({ day_from: '2026-05-20' })).toContain("r.date >= '2026-05-20'")
    expect(q({ day_to: '2026-05-20' })).toContain("r.date <= '2026-05-20'")
  })

  it('refuses a timestamp where a date is expected, as production does with 422', () => {
    expect(() => q({ day_from: '2026-05-20T08:00:00+00:00' })).toThrow(BadRequest)
  })

  it('refuses a malformed date', () => {
    expect(() => q({ day_from: 'nope' })).toThrow(BadRequest)
  })
})

describe('get_count', () => {
  it('selects a count and drops ordering, limit and offset', () => {
    const { sql, isCount } = buildQuery(
      routes,
      new URLSearchParams({ get_count: 'true', limit: '5', order_by: 'id asc', offset: '3' }),
    )
    expect(isCount).toBe(true)
    expect(sql).toContain('SELECT count()')
    expect(sql).not.toContain('ORDER BY')
    expect(sql).not.toContain('LIMIT')
    expect(sql).not.toContain('OFFSET')
  })

  it('still applies filters', () => {
    const { sql } = buildQuery(
      routes,
      new URLSearchParams({ get_count: 'true', line_refs: '7' }),
    )
    expect(sql).toContain('r.line_ref IN (7)')
  })
})
