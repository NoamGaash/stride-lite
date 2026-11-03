import { describe, it, expect } from 'vitest'

const PROD = process.env.PROD_API ?? 'https://open-bus-stride-api.hasadna.org.il'
const LOCAL = process.env.LOCAL_API ?? 'http://127.0.0.1:8080'

/**
 * Production is a live service run by a non-profit, not a test environment, so
 * requests are spaced out and the case list stays small.
 */
const DELAY_MS = Number(process.env.DIFF_DELAY_MS ?? 400)

/**
 * The local database comes from the 2026-06-14 dump, whose data ends
 * 2026-05-29. Cases must stay inside that window or they fail for a reason
 * that is not a defect.
 */
const DAY = '2026-05-20'

/**
 * A gtfs_route whose rides fall inside the dump window. Filtering
 * `/gtfs_rides/list` on this indexed equality is the only shape production
 * answers without timing out.
 */
const ROUTE_ID = '8953903'

interface Case {
  path: string
  params: Record<string, string>
}

/**
 * Row order is fully determined, so cases exercise the default and not only an
 * explicit `order_by`. Which default applies depends on how the handler is
 * declared: `/siri_routes/list` declares the parameter with a default of
 * `'id asc'`, while `/gtfs_stops/list` declares none and therefore always
 * orders by `id DESC` — confirmed against production, where an `order_by` sent
 * to `/gtfs_stops/list` changes nothing.
 *
 * Two kinds of case are excluded, both because the local database is built from
 * the 2026-06-14 dump while production keeps growing, and neither because of
 * anything the implementation does:
 *
 *   - unfiltered `get_count`, whose totals move with production;
 *   - descending order by id with no filter, which reads the newest rows and so
 *     by construction asks for rows the dump does not contain. Measured: the
 *     highest `/siri_routes/list` id is 19132 in production and 17846 here.
 *
 * A third kind is excluded for a different reason: some queries production
 * cannot answer at all. `/gtfs_rides/list` filtered by `gtfs_route__date` or by
 * `start_time` hits PostgreSQL's statement timeout — measured at 64s before it
 * gave up, against 1.2s and 8.0s for the same two queries here. There is
 * nothing to compare against a timeout, so those cases use an indexed equality
 * filter instead, and the timeout is recorded as a finding rather than a case.
 *
 * Ascending order by id is unaffected, since the oldest rows do not move, and a
 * descending case is still comparable once a filter bounds it to a window that
 * closed before the dump was taken.
 */
const cases: Case[] = [
  // no joins, small tables: the contract's simplest shape
  { path: '/siri_routes/list', params: { limit: '5' } },
  { path: '/siri_routes/list', params: { limit: '5', offset: '10', order_by: 'id asc' } },
  { path: '/siri_routes/list', params: { limit: '20', order_by: 'line_ref asc' } },
  { path: '/siri_stops/list', params: { limit: '10' } },

  // date filtering
  { path: '/gtfs_stops/list', params: { date_from: DAY, date_to: DAY, limit: '10' } },
  {
    path: '/gtfs_routes/list',
    params: { date_from: DAY, date_to: DAY, limit: '10', order_by: 'id desc' },
  },
  {
    path: '/gtfs_stops/list',
    params: { date_from: DAY, date_to: DAY, get_count: 'true' },
  },
  { path: '/gtfs_routes/list', params: { date_from: DAY, date_to: DAY, limit: '10', order_by: 'id asc' } },
  {
    path: '/gtfs_routes/list',
    params: { date_from: DAY, date_to: DAY, limit: '5', order_by: 'line_ref asc' },
  },

  // an order_by sent to an endpoint that declares none must be ignored
  {
    path: '/gtfs_stops/list',
    params: { date_from: DAY, date_to: DAY, limit: '10', order_by: 'code desc' },
  },

  // prefix filtering
  {
    path: '/siri_snapshots/list',
    params: { snapshot_id_prefix: '2026/05/20', limit: '10', order_by: 'id asc' },
  },

  // three joins, two of them outer: the gtfs_* fields must come back null on an
  // unmatched row rather than as ClickHouse's column defaults
  {
    path: '/siri_rides/list',
    params: {
      scheduled_start_time_from: `${DAY}T05:00:00+00:00`,
      scheduled_start_time_to: `${DAY}T05:05:00+00:00`,
      limit: '5',
      order_by: 'id asc',
    },
  },
  {
    path: '/siri_rides/list',
    params: {
      scheduled_start_time_from: `${DAY}T00:00:00+00:00`,
      scheduled_start_time_to: `${DAY}T00:06:00+00:00`,
      limit: '10',
      order_by: 'id desc',
    },
  },
  {
    path: '/siri_rides/list',
    params: {
      scheduled_start_time_from: `${DAY}T05:00:00+00:00`,
      scheduled_start_time_to: `${DAY}T06:00:00+00:00`,
      gtfs_route__date_from: DAY,
      gtfs_route__date_to: DAY,
      limit: '10',
      order_by: 'scheduled_start_time asc',
    },
  },
  {
    path: '/siri_rides/list',
    params: {
      scheduled_start_time_from: `${DAY}T05:00:00+00:00`,
      scheduled_start_time_to: `${DAY}T05:30:00+00:00`,
      get_count: 'true',
    },
  },

  // one inner join, filtered the only way production can answer quickly
  { path: '/gtfs_rides/list', params: { gtfs_route_id: ROUTE_ID, limit: '10', order_by: 'id asc' } },
  {
    path: '/gtfs_rides/list',
    params: { gtfs_route_id: ROUTE_ID, limit: '5', offset: '3', order_by: 'start_time asc' },
  },
  { path: '/gtfs_rides/list', params: { gtfs_route_id: ROUTE_ID, get_count: 'true' } },

  // the four-way inner join, the heaviest endpoint
  {
    path: '/siri_vehicle_locations/list',
    params: {
      recorded_at_time_from: `${DAY}T08:00:00+00:00`,
      recorded_at_time_to: `${DAY}T08:05:00+00:00`,
      limit: '20',
      order_by: 'id asc',
    },
  },
  {
    path: '/siri_vehicle_locations/list',
    params: {
      recorded_at_time_from: `${DAY}T08:00:00+00:00`,
      recorded_at_time_to: `${DAY}T08:01:00+00:00`,
      get_count: 'true',
    },
  },
  {
    path: '/siri_vehicle_locations/list',
    params: {
      recorded_at_time_from: `${DAY}T08:00:00+00:00`,
      recorded_at_time_to: `${DAY}T09:00:00+00:00`,
      lat__greater_or_equal: '32.0',
      lat__lower_or_equal: '32.15',
      lon__greater_or_equal: '34.7',
      lon__lower_or_equal: '34.9',
      limit: '25',
      order_by: 'distance_from_siri_ride_stop_meters desc',
    },
  },

  // an empty range must come back empty rather than erroring
  {
    path: '/siri_vehicle_locations/list',
    params: {
      recorded_at_time_from: `${DAY}T08:00:00+00:00`,
      recorded_at_time_to: `${DAY}T08:00:00+00:00`,
      limit: '10',
      order_by: 'id asc',
    },
  },
]

/**
 * Differences that are legitimate rather than defects. Every entry needs a
 * reason: a list that grows quietly is how a comparison like this stops
 * meaning anything.
 */
const ALLOWED_DIFFS: { path: string; field: string; why: string }[] = []

function url(base: string, c: Case): string {
  const u = new URL(base + c.path)
  for (const [k, v] of Object.entries(c.params)) u.searchParams.set(k, v)
  return u.toString()
}

async function fetchJson(target: string): Promise<{ status: number; body: unknown }> {
  const res = await fetch(target, { headers: { accept: 'application/json' } })
  const text = await res.text()
  let body: unknown = text
  try {
    body = JSON.parse(text)
  } catch {
    // a non-JSON body is itself the thing to compare
  }
  return { status: res.status, body }
}

/** Drops fields that are allowed to differ, so the rest must match exactly. */
function strip(path: string, value: unknown): unknown {
  const fields = ALLOWED_DIFFS.filter((d) => d.path === path).map((d) => d.field)
  if (fields.length === 0) return value
  const clean = (row: unknown): unknown => {
    if (row === null || typeof row !== 'object') return row
    const out: Record<string, unknown> = { ...(row as Record<string, unknown>) }
    for (const f of fields) delete out[f]
    return out
  }
  return Array.isArray(value) ? value.map(clean) : clean(value)
}

const label = (c: Case) =>
  `${c.path} ${
    Object.entries(c.params)
      .map(([k, v]) => `${k}=${v}`)
      .join('&') || '(defaults)'
  }`

describe('responses match production', () => {
  for (const c of cases) {
    it(
      label(c),
      async () => {
        await new Promise((r) => setTimeout(r, DELAY_MS))
        const [prod, local] = await Promise.all([fetchJson(url(PROD, c)), fetchJson(url(LOCAL, c))])
        expect(local.status, 'http status').toBe(prod.status)
        expect(strip(c.path, local.body)).toStrictEqual(strip(c.path, prod.body))
      },
      60_000,
    )
  }
})
