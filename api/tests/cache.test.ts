import { describe, it, expect } from 'vitest'
import { cacheControl, listEnds, windowEnd } from '../src/cache'
import { endpoints } from '../src/registry'
import { rawEndpoints } from '../src/raw'

const DAY = 86_400_000
const now = Date.parse('2026-11-13T12:00:00Z')
const q = (s: string) => new URLSearchParams(s)

describe('how long a response may be cached', () => {
  it.each([
    ['2026-11-12', 'max-age=900'],
    ['2026-11-06', 'max-age=900'],
    ['2026-11-05', 'max-age=86400'],
    ['2026-10-14', 'max-age=86400'],
    ['2026-10-13', 'max-age=172800'],
  ])('a window ending %s', (day, want) => {
    expect(cacheControl({}, windowEnd(['d'], q(`d=${day}`)), now)).toBe(want)
  })

  it('is short when the request names no end, since it reaches the present', () => {
    expect(cacheControl({}, undefined, now)).toBe('max-age=900')
  })

  it('is never stored for an endpoint marked so', () => {
    expect(cacheControl({ cache: 'none' }, now - 365 * DAY, now)).toBe('no-store')
  })
})

describe('where a request ends', () => {
  it('is the end of the latest day any of its end parameters names', () => {
    expect(windowEnd(['a', 'b'], q('a=2026-01-01&b=2026-02-01T23:30:00+02:00'))).toBe(
      Date.parse('2026-02-02T00:00:00Z'),
    )
  })

  it('is unknown when no end parameter was sent, or one cannot be read', () => {
    expect(windowEnd(['a'], q('b=2026-01-01'))).toBeUndefined()
    expect(windowEnd(['a', 'b'], q('a=2026-01-01&b=soon'))).toBeUndefined()
    expect(windowEnd([], q(''))).toBeUndefined()
  })
})

describe('the endpoints', () => {
  it('end a list request at its upper time bounds', () => {
    const vl = endpoints.find((e) => e.path === '/siri_vehicle_locations/list')!
    expect(windowEnd(listEnds(vl), q('recorded_at_time_from=2020-01-01T00:00:00Z'))).toBeUndefined()
    expect(windowEnd(listEnds(vl), q('recorded_at_time_to=2026-01-01T10:00:00Z'))).toBe(
      Date.parse('2026-01-02T00:00:00Z'),
    )
  })

  it('end a velocity request with the day it asks about', () => {
    const v = rawEndpoints.find((e) => e.path === '/siri_velocity_aggregation/siri_velocity_aggregation')!
    expect(windowEnd(v.windowEnd!, q('recorded_from=2026-01-01T10:00:00Z'), v.windowEndDaysLater)).toBe(
      Date.parse('2026-01-03T00:00:00Z'),
    )
  })
})
