import { describe, it, expect } from 'vitest'

const LOCAL = process.env.LOCAL_API ?? 'http://127.0.0.1:8080'

/**
 * An hour old enough that every ride in it has finished and its locations have
 * settled, inside the months this database holds.
 */
const FROM = '2026-06-02T04:00:00+03:00'
const TO = '2026-06-02T05:00:00+03:00'

type Ride = {
  id: number
  duration_minutes: number | null
  first_vehicle_location_id: number | null
  last_vehicle_location_id: number | null
}

type Location = { id: number; recorded_at_time: string; siri_ride__id: number }

async function get<T>(path: string): Promise<T> {
  const res = await fetch(`${LOCAL}${path}`)
  if (!res.ok) throw new Error(`${path}: ${res.status} ${await res.text()}`)
  return (await res.json()) as T
}

const settledRides = () =>
  get<Ride[]>(
    `/siri_rides/list?limit=300` +
      `&scheduled_start_time_from=${encodeURIComponent(FROM)}` +
      `&scheduled_start_time_to=${encodeURIComponent(TO)}`,
  )

describe('ride durations', () => {
  it('serves a duration for rides whose locations have settled', async () => {
    const rides = await settledRides()
    expect(rides.length).toBeGreaterThan(50)

    const withDuration = rides.filter((r) => r.duration_minutes !== null)
    // Not every ride has locations — one that was announced and never reported
    // has nothing to measure — but an hour of real traffic is mostly rides that
    // ran, so a null here for the clear majority means the pass is not running.
    expect(withDuration.length / rides.length).toBeGreaterThan(0.8)
  })

  it('names a first and last location whenever it gives a duration', async () => {
    const rides = await settledRides()
    const withDuration = rides.filter((r) => r.duration_minutes !== null)
    expect(withDuration.length).toBeGreaterThan(0)

    for (const ride of withDuration) {
      expect(ride.first_vehicle_location_id).not.toBeNull()
      expect(ride.last_vehicle_location_id).not.toBeNull()
    }
  })

  it('the duration is the span between the two locations it names', async () => {
    const rides = await settledRides()
    const ride = rides.find((r) => (r.duration_minutes ?? 0) > 0)
    expect(ride, 'no ride with a positive duration to check').toBeDefined()

    const ids = [ride!.first_vehicle_location_id, ride!.last_vehicle_location_id]
    const locations = await get<Location[]>(
      `/siri_vehicle_locations/list?limit=2&siri_vehicle_location_ids=${ids.join(',')}`,
    )
    expect(locations).toHaveLength(2)

    const times = locations.map((l) => new Date(l.recorded_at_time).getTime()).sort()
    const minutes = Math.round((times[1] - times[0]) / 60000)
    expect(minutes).toBe(ride!.duration_minutes)
  })

  it('names locations that belong to the ride', async () => {
    const rides = await settledRides()
    const ride = rides.find((r) => (r.duration_minutes ?? 0) > 0)
    expect(ride).toBeDefined()

    // Asked of the two locations rather than of the ride's whole track: the
    // locations endpoint reports which ride each reading belongs to, so two
    // rows answer it where `siri_rides__ids` would read thousands.
    const ends = await get<Location[]>(
      `/siri_vehicle_locations/list?limit=2&siri_vehicle_location_ids=` +
        `${ride!.first_vehicle_location_id},${ride!.last_vehicle_location_id}`,
    )
    expect(ends).toHaveLength(2)
    for (const end of ends) expect(end.siri_ride__id).toBe(ride!.id)
  })

  it('never reports a duration without the locations behind it', async () => {
    const rides = await settledRides()
    // Production's add_ride_durations.py has a second pass that writes
    // duration_minutes = 0 for rides it gave up on, leaving a measurement that
    // was never measured. A zero here has to come from readings that exist.
    const zeros = rides.filter((r) => r.duration_minutes === 0)
    for (const ride of zeros) {
      expect(ride.first_vehicle_location_id).not.toBeNull()
      expect(ride.last_vehicle_location_id).not.toBeNull()
    }

    // The two need not be the same location: a stalled feed repeats a vehicle
    // across many snapshots without advancing recorded_at_time, so a zero is
    // commonly two distinct ids. What a zero does mean is that they share a time.
    const zero = zeros[0]
    if (zero) {
      const ends = await get<Location[]>(
        `/siri_vehicle_locations/list?limit=2&siri_vehicle_location_ids=` +
          `${zero.first_vehicle_location_id},${zero.last_vehicle_location_id}`,
      )
      const times = new Set(ends.map((l) => l.recorded_at_time))
      expect(times.size).toBe(1)
    }
  })
})
