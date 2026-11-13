import { describe, it, expect } from 'vitest'
import spec from '../openapi.json' with { type: 'json' }

const PROD = process.env.PROD_API ?? 'https://open-bus-stride-api.hasadna.org.il'
const LOCAL = process.env.LOCAL_API ?? 'http://127.0.0.1:8080'

/**
 * Production is a live service run by a non-profit, not a test environment, so
 * requests are spaced out and each case is asked once.
 */
const DELAY_MS = Number(process.env.DIFF_DELAY_MS ?? 400)

/**
 * Cases stay inside the window where the two databases hold the same rows, and
 * that window is bounded at BOTH ends, which is easy to get wrong:
 *
 *   - the 2026-06-14 dump's data ends 2026-05-29, so nothing later exists here;
 *   - production deletes old vehicle locations. Its oldest `siri_vehicle_location`
 *     is 2025-01-01, and a 2023 row this database still holds
 *     (id 1830886657) answers 404 there.
 *
 * So the dump is not a subset of production: it is a different set, and a
 * comparison is only meaningful in the intersection, 2025-01-01 to 2026-05-29.
 */
const DAY = '2026-05-20'

/** A gtfs_route, and a ride of it, both inside the window. */
const ROUTE_ID = '8953903'
const GTFS_RIDE_ID = '144732116'

/** One id per table, the lowest inside the window, for the `/get` endpoints. */
const IDS = {
  siri_route: '1',
  siri_stop: '1',
  gtfs_stop: '44980981',
  gtfs_route: '8953416',
  gtfs_ride: GTFS_RIDE_ID,
  gtfs_ride_stop: '5173161605',
  siri_ride: '136828319',
  siri_ride_stop: '3492929357',
  siri_snapshot: '2234591',
  siri_vehicle_location: '7910843165',
}

interface Case {
  path: string
  params: Record<string, string>
  /**
   * The endpoint emits no ORDER BY, so row order is whatever the engine
   * produced and only the set of rows is part of the contract.
   */
  unordered?: boolean
  /**
   * Production cannot answer this shape at all — PostgreSQL's statement timeout
   * fires before it returns. There is nothing to compare against a timeout, so
   * the case asserts only that this implementation answers, and the timeout is
   * reported as a finding.
   */
  prodTimesOut?: boolean
}

const cases: Case[] = [
  // ---- small tables, no joins ----
  { path: '/siri_routes/list', params: { limit: '5' } },
  { path: '/siri_routes/list', params: { limit: '5', offset: '10', order_by: 'id asc' } },
  { path: '/siri_routes/list', params: { limit: '20', order_by: 'line_ref asc' } },
  { path: '/siri_stops/list', params: { limit: '10' } },
  { path: '/siri_routes/get', params: { id: IDS.siri_route } },
  { path: '/siri_stops/get', params: { id: IDS.siri_stop } },

  // ---- date filtering ----
  { path: '/gtfs_stops/list', params: { date_from: DAY, date_to: DAY, limit: '10' } },
  { path: '/gtfs_stops/list', params: { date_from: DAY, date_to: DAY, get_count: 'true' } },
  { path: '/gtfs_routes/list', params: { date_from: DAY, date_to: DAY, limit: '10', order_by: 'id desc' } },
  { path: '/gtfs_routes/list', params: { date_from: DAY, date_to: DAY, limit: '10', order_by: 'id asc' } },
  { path: '/gtfs_routes/list', params: { date_from: DAY, date_to: DAY, limit: '5', order_by: 'line_ref asc' } },
  { path: '/gtfs_stops/get', params: { id: IDS.gtfs_stop } },
  { path: '/gtfs_routes/get', params: { id: IDS.gtfs_route } },

  // an order_by sent to an endpoint that declares none must be ignored
  { path: '/gtfs_stops/list', params: { date_from: DAY, date_to: DAY, limit: '10', order_by: 'code desc' } },

  // ---- prefix filtering ----
  { path: '/siri_snapshots/list', params: { snapshot_id_prefix: '2026/05/20', limit: '10', order_by: 'id asc' } },
  { path: '/siri_snapshots/get', params: { id: IDS.siri_snapshot } },

  // ---- three joins, two outer ----
  {
    path: '/siri_rides/list',
    params: { scheduled_start_time_from: `${DAY}T05:00:00+00:00`, scheduled_start_time_to: `${DAY}T05:05:00+00:00`, limit: '5', order_by: 'id asc' },
  },
  {
    path: '/siri_rides/list',
    params: { scheduled_start_time_from: `${DAY}T00:00:00+00:00`, scheduled_start_time_to: `${DAY}T00:06:00+00:00`, limit: '10', order_by: 'id desc' },
  },
  {
    path: '/siri_rides/list',
    params: { scheduled_start_time_from: `${DAY}T05:00:00+00:00`, scheduled_start_time_to: `${DAY}T06:00:00+00:00`, gtfs_route__date_from: DAY, gtfs_route__date_to: DAY, limit: '10', order_by: 'scheduled_start_time asc' },
  },
  {
    path: '/siri_rides/list',
    params: { scheduled_start_time_from: `${DAY}T05:00:00+00:00`, scheduled_start_time_to: `${DAY}T05:30:00+00:00`, get_count: 'true' },
  },
  { path: '/siri_rides/get', params: { id: IDS.siri_ride } },

  // ---- one inner join, filtered the only way production answers quickly ----
  { path: '/gtfs_rides/list', params: { gtfs_route_id: ROUTE_ID, limit: '10', order_by: 'id asc' } },
  { path: '/gtfs_rides/list', params: { gtfs_route_id: ROUTE_ID, limit: '5', offset: '3', order_by: 'start_time asc' } },
  { path: '/gtfs_rides/list', params: { gtfs_route_id: ROUTE_ID, get_count: 'true' } },
  { path: '/gtfs_rides/get', params: { id: IDS.gtfs_ride } },

  // ---- the four-way inner join, the heaviest endpoint ----
  {
    path: '/siri_vehicle_locations/list',
    params: { recorded_at_time_from: `${DAY}T08:00:00+00:00`, recorded_at_time_to: `${DAY}T08:05:00+00:00`, limit: '20', order_by: 'id asc' },
  },
  {
    path: '/siri_vehicle_locations/list',
    params: { recorded_at_time_from: `${DAY}T08:00:00+00:00`, recorded_at_time_to: `${DAY}T08:01:00+00:00`, get_count: 'true' },
  },
  // The shape `Date.toISOString()` produces, which is every call the frontend
  // makes and which none of the cases above were sending.
  {
    path: '/siri_vehicle_locations/list',
    params: { recorded_at_time_from: `${DAY}T08:00:00.000Z`, recorded_at_time_to: `${DAY}T08:01:00.000Z`, limit: '20', order_by: 'id asc' },
  },
  {
    path: '/siri_vehicle_locations/list',
    params: {
      recorded_at_time_from: `${DAY}T08:00:00+00:00`, recorded_at_time_to: `${DAY}T09:00:00+00:00`,
      lat__greater_or_equal: '32.0', lat__lower_or_equal: '32.15',
      lon__greater_or_equal: '34.7', lon__lower_or_equal: '34.9',
      limit: '25', order_by: 'distance_from_siri_ride_stop_meters desc',
    },
  },
  // an empty range must come back empty rather than erroring
  {
    path: '/siri_vehicle_locations/list',
    params: { recorded_at_time_from: `${DAY}T08:00:00+00:00`, recorded_at_time_to: `${DAY}T08:00:00+00:00`, limit: '10', order_by: 'id asc' },
  },
  { path: '/siri_vehicle_locations/get', params: { id: IDS.siri_vehicle_location } },

  // ---- the two ride-stop tables ----
  { path: '/gtfs_ride_stops/list', params: { gtfs_ride_ids: GTFS_RIDE_ID, limit: '20', order_by: 'id asc' } },
  { path: '/gtfs_ride_stops/list', params: { gtfs_ride_ids: GTFS_RIDE_ID, get_count: 'true' } },
  { path: '/gtfs_ride_stops/get', params: { id: IDS.gtfs_ride_stop } },
  {
    path: '/siri_ride_stops/list',
    params: { siri_ride_ids: IDS.siri_ride, limit: '20' },
  },
  { path: '/siri_ride_stops/get', params: { id: IDS.siri_ride_stop } },

  // ---- the seven hand-written aggregate endpoints ----
  { path: '/gtfs_agencies/list', params: { date_from: DAY, date_to: DAY, limit: '20' } },
  { path: '/gtfs_agencies/list', params: { date_from: DAY, date_to: DAY, limit: '5', offset: '3' } },
  // Production cannot serve this one: measured at an 86 s and a 103 s statement
  // timeout on a single day. The data behind it is verified through
  // /gtfs_rides_agg/group_by below, which reads the same aggregate and does
  // answer; what stays unverified is only this handler's row shaping.
  {
    path: '/gtfs_rides_agg/list',
    params: { date_from: DAY, date_to: DAY, limit: '5' },
    prodTimesOut: true,
  },
  {
    path: '/gtfs_rides_agg/group_by',
    params: { date_from: DAY, date_to: DAY, group_by: 'operator_ref' },
    unordered: true,
  },
  {
    path: '/gtfs_rides_agg/group_by',
    params: { date_from: DAY, date_to: DAY, group_by: 'gtfs_route_date,operator_ref' },
    unordered: true,
  },
  // On DAY every num_actual_rides is 0, because the ETL that fills
  // siri_ride.scheduled_time_gtfs_ride_id collapsed in September 2024 and has
  // been exactly zero since January 2025. That makes DAY useless for checking
  // the one subtle part of the aggregate: upstream's count(*) over a LEFT JOIN
  // counts a gtfs_ride once per matching siri_ride. This date still has real
  // matches — 608 actual of 909 planned for operator 2 — so it is what verifies
  // `sum(greatest(n, 1))`.
  {
    path: '/gtfs_rides_agg/group_by',
    params: { date_from: '2024-08-14', date_to: '2024-08-14', group_by: 'operator_ref' },
    unordered: true,
  },
  {
    path: '/rides_execution/list',
    params: { date_from: DAY, date_to: DAY, operator_ref: '21', line_ref: '10746', limit: '20' },
  },
  {
    path: '/rides_execution/list',
    params: { date_from: DAY, date_to: DAY, operator_ref: '21', line_ref: '10746', get_count: 'true' },
  },
  {
    path: '/route_timetable/list',
    params: {
      planned_start_time_date_from: `${DAY}T08:00:00+00:00`,
      planned_start_time_date_to: `${DAY}T08:30:00+00:00`,
      line_refs: '10746',
      limit: '10',
    },
  },
  // Both sides return nothing, and that is the whole contract this endpoint can
  // still be held to — see STOP_ARRIVALS_IS_DEAD below.
  { path: '/stop_arrivals/list', params: { gtfs_stop_id: '44980981', limit: '10' } },
  { path: '/stop_arrivals/list', params: { gtfs_ride_ids: GTFS_RIDE_ID, limit: '5' } },
  {
    path: '/siri_velocity_aggregation/siri_velocity_aggregation',
    params: {
      recorded_from: `${DAY}T00:00:00+00:00`,
      lon_min: '34.78', lon_max: '34.80', lat_min: '32.07', lat_max: '32.09',
      rounding_precision: '6',
    },
  },
]

/**
 * Differences that are legitimate rather than defects. Every entry states why,
 * because a list that grows quietly is how a comparison like this stops meaning
 * anything.
 */
const ALLOWED_DIFFS: {
  path: string
  field: string
  why: string
  /**
   * Drop the field only on rows where production has no value. Everything
   * production does answer stays compared, which is the difference between an
   * exception and a blind spot.
   */
  onlyWhereProductionIsNull?: boolean
}[] = [
  {
    path: '/siri_velocity_aggregation/siri_velocity_aggregation',
    field: 'average_rolling_avg',
    why:
      'The rolling average uses ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING over ' +
      'ORDER BY recorded_at_time, and that order has ties: 38,230 of 74,320 rows ' +
      'in the measured window share a timestamp with another row. With a ROWS ' +
      'frame the window contents then depend on physical row order, which no ' +
      'engine defines. Measured: three identical calls to THIS implementation ' +
      'returned three different values, so the field is not reproducible in ' +
      'production either and cannot be compared byte for byte.',
  },
  {
    path: '/siri_velocity_aggregation/siri_velocity_aggregation',
    field: 'stddev_rolling_avg',
    why: 'Same cause as average_rolling_avg above.',
  },
  ...[
    { path: '/siri_rides/list', prefix: '' },
    { path: '/siri_rides/get', prefix: '' },
    { path: '/siri_vehicle_locations/list', prefix: 'siri_ride__' },
    { path: '/siri_ride_stops/list', prefix: 'siri_ride__' },
  ].flatMap(({ path, prefix }) =>
    ['duration_minutes', 'first_vehicle_location_id', 'last_vehicle_location_id'].map(
      (field) => ({
        path,
        field: `${prefix}${field}`,
        onlyWhereProductionIsNull: true,
        why: 'Production stopped measuring ride durations in December 2024 — 7 rides of ' +
      '3,086,370 that month, and none at all from 2025-01 on, which is why ' +
      'docs/FINDINGS.md #13 exists. Every case here sits in 2025-01-01..2026-05-29, ' +
      'so production answers null for all three and this implementation answers ' +
      'what the locations say. Deliberate: the user ruled that fixing a production ' +
      'defect justifies diverging from it. Verified against a day production did ' +
      'measure, 2024-09-10, where the duration matches on 108,230 of 108,237 rides; ' +
      'the two ids are not reproducible even in principle, because production picks ' +
      'among readings sharing one recorded_at_time in scan order.',
      }),
    ),
  ),
]

/**
 * `/stop_arrivals/list` cannot return a row from production, for any input.
 * Measured, and worth stating because it looks like a defect in this
 * implementation and is not one:
 *
 *   - the endpoint joins siri_ride_stop.nearest_siri_vehicle_location_id to
 *     siri_vehicle_location;
 *   - the newest value that column ever received is 4968453124, which is a
 *     vehicle location recorded 2024-12-04, so the ETL that fills it
 *     (siri-update-ride-stops-vehicle-locations) stopped then;
 *   - production's oldest surviving vehicle location is 2025-01-01.
 *
 * The two windows do not overlap, so the join matches nothing there. This
 * database still holds the older rows, so the same SQL returns them here. The
 * join tree is identical to production's own, which its timeout message prints
 * in full; the difference is retention, not logic.
 */
const STOP_ARRIVALS_IS_DEAD = true
void STOP_ARRIVALS_IS_DEAD

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

/**
 * Drops fields that are allowed to differ, so everything else must match
 * exactly. `production` is the other side, needed by the conditional entries;
 * rows are paired by position, which is why no conditional entry is used on an
 * endpoint marked `unordered`.
 */
function strip(path: string, value: unknown, production: unknown): unknown {
  const diffs = ALLOWED_DIFFS.filter((d) => d.path === path)
  if (diffs.length === 0) return value
  const clean = (row: unknown, prodRow: unknown): unknown => {
    if (row === null || typeof row !== 'object') return row
    const out: Record<string, unknown> = { ...(row as Record<string, unknown>) }
    const theirs = (prodRow ?? {}) as Record<string, unknown>
    for (const d of diffs) {
      if (d.onlyWhereProductionIsNull && theirs[d.field] !== null) continue
      delete out[d.field]
    }
    return out
  }
  if (!Array.isArray(value)) return clean(value, production)
  const prodRows = Array.isArray(production) ? production : []
  return value.map((row, i) => clean(row, prodRows[i]))
}

/** For an endpoint that emits no ORDER BY, compare the rows as a set. */
function canonical(value: unknown): unknown {
  if (!Array.isArray(value)) return value
  return [...value].map((r) => JSON.stringify(r)).sort()
}

const label = (c: Case) =>
  `${c.path} ${Object.entries(c.params).map(([k, v]) => `${k}=${v}`).join('&') || '(defaults)'}`

describe('every endpoint in the published spec has a case', () => {
  it('covers all of them', () => {
    const published = Object.entries(spec.paths as Record<string, Record<string, unknown>>)
      .filter(([, v]) => 'get' in v)
      .map(([p]) => p)
      .sort()
    const covered = [...new Set(cases.map((c) => c.path))].sort()
    expect(published.filter((p) => !covered.includes(p))).toStrictEqual([])
    expect(covered.filter((p) => !published.includes(p))).toStrictEqual([])
  })
})

describe('responses match production', () => {
  for (const c of cases) {
    it(
      label(c),
      async () => {
        await new Promise((r) => setTimeout(r, DELAY_MS))
        if (c.prodTimesOut) {
          const local = await fetchJson(url(LOCAL, c))
          expect(local.status, 'this implementation must still answer').toBe(200)
          expect(Array.isArray(local.body)).toBe(true)
          return
        }
        const [prod, local] = await Promise.all([fetchJson(url(PROD, c)), fetchJson(url(LOCAL, c))])
        expect(local.status, 'http status').toBe(prod.status)
        const l = strip(c.path, local.body, prod.body)
        const p = strip(c.path, prod.body, prod.body)
        if (c.unordered) expect(canonical(l)).toStrictEqual(canonical(p))
        else expect(l).toStrictEqual(p)
      },
      180_000,
    )
  }
})
