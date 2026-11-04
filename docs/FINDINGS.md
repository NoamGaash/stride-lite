# What reimplementing the API found out about the API

[עברית](FINDINGS.he.md)

Rebuilding 27 endpoints and comparing every one against production turns up
things that are invisible from either side alone. These are about the **running
service**, not about this experiment, and they are listed here because they are
the part of this work most useful to the project whatever happens to the rest
of it.

Everything below was measured against the live API and the public dump. Nothing
here required access to Hasadna's database.

---

## 1. `/stop_arrivals/list` cannot return a row, for any input

The endpoint joins `siri_ride_stop.nearest_siri_vehicle_location_id` to
`siri_vehicle_location`. Both ends of that join have moved out from under it:

| | |
| --- | --- |
| Newest value `nearest_siri_vehicle_location_id` ever received | `4968453124`, a vehicle location recorded **2024-12-04** |
| Oldest `siri_vehicle_location` production still holds | **2025-01-01** |

The windows do not overlap, so the join matches nothing. Production answers
`[]` for every stop and every ride we tried, including stops that demonstrably
had arrivals in 2023.

Two separate causes, and both are worth knowing:

- **`siri-update-ride-stops-vehicle-locations` stopped on 2024-12-04.** 1.27
  billion of 2.80 billion `siri_ride_stop` rows carry the column, and none newer
  than that date.
- **Vehicle locations are deleted after about two years**, which has since
  passed over everything the ETL managed to fill.

The endpoint's docstring already says "Currently, only planned time (gtfs) is
returned for every stop". In practice nothing is returned at all.

## 2. The public dump is not a subset of production

This one changes how any comparison has to be set up, and it is easy to get
backwards. The 2026-06-14 dump holds `siri_vehicle_location` rows back to
2022-11-08. Production's oldest is 2025-01-01, and a 2023 row the dump still
holds — `id = 1830886657` — answers **404** from the live API.

So the two databases are different sets, overlapping only between
**2025-01-01 and 2026-05-29**. A differential test outside that window fails for
a reason that is not a defect at either end.

## 3. Production times out on three of its own endpoints

Measured today, same parameters against both:

| Endpoint | Production | This implementation |
| --- | --- | --- |
| `/gtfs_rides_agg/list`, one day | **statement timeout at 86 s** | 0.040 s |
| `/stop_arrivals/list`, no filter | **statement timeout** | — |
| `/gtfs_agencies/list`, one day | 19.0 s | 0.011 s |
| `/gtfs_rides/list`, date range | statement timeout at 64 s | 1.2 s |

`/gtfs_agencies/list` answers, but 19 s for a `GROUP BY` over one day of
`gtfs_route` is a user-visible cost for something a column store does in
milliseconds.

## 4. `/siri_velocity_aggregation` is not reproducible

Its rolling average uses `ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING` over
`ORDER BY recorded_at_time`, and that order is not unique: **38,230 of 74,320
rows** in the measured window share a timestamp with another row. With a `ROWS`
frame the window's contents then depend on physical row order, which no engine
defines.

Measured on this implementation, which has the same shape: three identical
calls returned three different values for `stddev_rolling_avg`. The same must be
true in production. Anything consuming those two fields is consuming noise at the
third decimal.

A deterministic version needs a tiebreaker in the window's `ORDER BY`, or a
`RANGE` frame instead of `ROWS`.

## 5. `/siri_ride_stops/list` silently ignores `gtfs_stop_ids`

`?gtfs_stop_ids=13429736` returns the newest rows, whose `gtfs_stop_id` is
`null` — the parameter is not declared on that handler, so FastAPI drops it
without complaint. A caller gets a successful response to a filter that was
never applied, which is worse than an error.

## 6. The database backup has been stale for five months

`stride_db.sql.zst` answers `Last-Modified: Sun, 14 Jun 2026`, and the data
inside ends 2026-05-29. Re-checked 2026-11-04. The
`stride-etl-db-copy-backup-to-s3` DAG last succeeded in 2022.

This is unrelated to everything else here and is the most urgent of them: the
raw SIRI archive is intact and current, but a database rebuilt from it would
lose every ETL-derived table.

## 7. Two contract details that are not in the spec

Found by comparison, both of which silently corrupt a reimplementation:

- **A ride is identified by `(siri_route_id, journey_ref, vehicle_ref)`**, and
  `scheduled_start_time` is an attribute frozen when the row is created, not
  part of its identity. Keying on it splits one ride into several whenever the
  feed revises the departure time: 65 rows in one measured minute.
- **A monitored stop visit with no coordinates is dropped entirely**, not stored
  with nulls. Zero null locations in 432,143 production rows for an hour,
  against 407 empty ones in 335,227 raw rows for the same hour.

## 8. PostgreSQL's text ordering is not byte ordering

`/gtfs_agencies/list` orders by `agency_name` through the database's glibc
collation, which compares first ignoring punctuation and whitespace and then in
full. A byte comparison puts `"ירושלים - עיסאוויה…"` before `"ירושלים-אבו-תור…"`;
production puts it after `"ירושלים-דרום…"`. ClickHouse's `COLLATE 'he'` does not
reproduce it either, because ICU treats punctuation as significant by default.

Any client that re-sorts this list locally will disagree with the API.

---

## Reporting these

These are observations from outside, and some may have a reason we cannot see
from here. The intent is to open them as issues on the relevant `hasadna`
repositories, one each, with the measurement attached — not to assert they are
all defects.
