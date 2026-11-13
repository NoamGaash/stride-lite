import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { endpoints } from '../src/registry'
import { annotate, indexedColumns } from '../src/openapi'
import spec from '../openapi.json' with { type: 'json' }

const db = (name: string) => readFileSync(new URL(`../../db/${name}`, import.meta.url), 'utf8')
const indexed = indexedColumns(db('schema.sql'), db('projections.sql'))

describe('indexedColumns', () => {
  it('reads the leading sort column, the skip indexes and the projections', () => {
    expect([...indexed.get('siri_vehicle_location')!]).toEqual(
      expect.arrayContaining(['recorded_at_time', 'id']),
    )
    expect([...indexed.get('siri_ride_stop')!]).toEqual(
      expect.arrayContaining(['id', 'siri_ride_id', 'gtfs_stop_id']),
    )
    expect(indexed.get('siri_ride')!.has('journey_ref')).toBe(true)
    expect(indexed.get('siri_vehicle_location')!.has('lat')).toBe(false)
  })
})

describe('the served spec', () => {
  const served = annotate(spec, endpoints, indexed)
  const lookup = (path: string, name: string) =>
    served.paths[path].get!.parameters!.find((p) => p.name === name)!['x-lookup']

  it('tells a caller which parameters narrow the read and which scan', () => {
    expect(lookup('/siri_vehicle_locations/list', 'recorded_at_time_from')).toBe('indexed')
    expect(lookup('/siri_vehicle_locations/list', 'lat__greater_or_equal')).toBe('scan')
    expect(lookup('/siri_vehicle_locations/list', 'siri_routes__line_ref')).toBe('scan')
    expect(lookup('/siri_vehicle_locations/list', 'siri_rides__ids')).toBe('indexed')
    expect(lookup('/siri_ride_stops/list', 'siri_ride_ids')).toBe('indexed')
  })

  it('leaves paging and ordering unmarked, and the source spec untouched', () => {
    expect(lookup('/siri_vehicle_locations/list', 'limit')).toBeUndefined()
    expect(JSON.stringify(spec)).not.toContain('x-lookup')
  })
})
