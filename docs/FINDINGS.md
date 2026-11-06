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

## 1. "Actual rides" has been zero for two years

`siri_ride.scheduled_time_gtfs_ride_id` is what matches a ride that happened to
a ride that was planned. Summed out of the aggregate the API serves:

| Month | Planned rides | Actual rides |
| --- | --- | --- |
| 2024-07 | 3,085,318 | 2,883,279 |
| 2024-08 | 2,940,066 | 2,737,426 |
| 2024-09 | 3,000,929 | 1,469,770 |
| 2024-10 | 2,548,446 | **44** |
| 2024-11 | 2,839,647 | **24** |
| 2024-12 | 3,131,037 | **6** |
| 2025-01 onwards | ~2.9M a month | **0** |

So `/gtfs_rides_agg/list` and `/gtfs_rides_agg/group_by` report that no planned
ride has been executed since January 2025, for every operator and every line.
Anything built on that number — a dashboard panel comparing planned against
actual — has been showing zero for two years.

The matching degraded through September 2024 and stopped in October, which
looks like a process that broke rather than one that was turned off.

Verified against production, not only here: `/gtfs_rides_agg/group_by` for
2026-05-20 returns `total_actual_rides: 0` for all 36 operators from both, and
for 2024-08-14 both return the same real numbers for all 37 — 608 actual of 909
planned for operator 2. The implementation agrees with production; it is the
data that stopped.

## 2. `/stop_arrivals/list` cannot return a row, for any input

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

## 3. The public dump is not a subset of production

This one changes how any comparison has to be set up, and it is easy to get
backwards. The 2026-06-14 dump holds `siri_vehicle_location` rows back to
2022-11-08. Production's oldest is 2025-01-01, and a 2023 row the dump still
holds — `id = 1830886657` — answers **404** from the live API.

So the two databases are different sets, overlapping only between
**2025-01-01 and 2026-05-29**. A differential test outside that window fails for
a reason that is not a defect at either end.

## 4. Production times out on three of its own endpoints

Measured today, same parameters against both:

| Endpoint | Production | This implementation |
| --- | --- | --- |
| `/gtfs_rides_agg/list`, one day | **statement timeout at 86 s, 103 s and 63 s** | 0.040 s |
| `/stop_arrivals/list`, no filter | **statement timeout** | — |
| `/gtfs_agencies/list`, one day | 19.0 s | 0.011 s |
| `/gtfs_rides/list`, date range | statement timeout at 64 s | 1.2 s |

The three figures for `/gtfs_rides_agg/list` are three separate attempts, and the last was made
with a **600-second client timeout** to rule out the obvious explanation. It is not the client
giving up: the body carries PostgreSQL's own `canceling statement due to statement timeout`,
and prints the query it cancelled. The time varies with load; the outcome does not.

`/gtfs_agencies/list` answers, but 19 s for a `GROUP BY` over one day of
`gtfs_route` is a user-visible cost for something a column store does in
milliseconds.

## 5. `/siri_velocity_aggregation` is not reproducible

Its rolling average uses `ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING` over
`ORDER BY recorded_at_time`, and that order is not unique: **38,230 of 74,320
rows** in the measured window share a timestamp with another row. With a `ROWS`
frame the window's contents then depend on physical row order, which no engine
defines.

Measured on this implementation, which has the same shape: three identical
calls returned three different values for `stddev_rolling_avg`. The same must be
true in production. Anything consuming those two fields is consuming noise at the
third decimal.

**Narrowing the window does not fix it**, which is worth stating because it is the
first thing anyone tries. On a single hour of an old day inside a 0.01° box, three identical
calls still disagreed. The structure of why: that window holds 35 groups of rows sharing a
cell and a timestamp, and **4 of them carry more than one distinct velocity**. A tie whose
rows are identical is harmless — reordering identical values changes nothing — so it takes
only those four to move the result, and the cells without them returned the same value every
time. Determinism here is per cell, not per query.

A deterministic version needs a tiebreaker in the window's `ORDER BY`, or a
`RANGE` frame instead of `ROWS`.

## 6. `/siri_ride_stops/list` silently ignores `gtfs_stop_ids`

`?gtfs_stop_ids=13429736` returns the newest rows, whose `gtfs_stop_id` is
`null` — the parameter is not declared on that handler, so FastAPI drops it
without complaint. A caller gets a successful response to a filter that was
never applied, which is worse than an error.

## 7. The database backup has been stale for five months

`stride_db.sql.zst` answers `Last-Modified: Sun, 14 Jun 2026`, and the data
inside ends 2026-05-29. Re-checked 2026-11-04. The
`stride-etl-db-copy-backup-to-s3` DAG last succeeded in 2022.

This is unrelated to everything else here and is the most urgent of them: the
raw SIRI archive is intact and current, but a database rebuilt from it would
lose every ETL-derived table.

## 8. Two contract details that are not in the spec

Found by comparison, both of which silently corrupt a reimplementation:

- **A ride is identified by `(siri_route_id, journey_ref, vehicle_ref)`**, and
  `scheduled_start_time` is an attribute frozen when the row is created, not
  part of its identity. Keying on it splits one ride into several whenever the
  feed revises the departure time: 65 rows in one measured minute.
- **A monitored stop visit with no coordinates is dropped entirely**, not stored
  with nulls. Zero null locations in 432,143 production rows for an hour,
  against 407 empty ones in 335,227 raw rows for the same hour.

## 9. PostgreSQL's text ordering is not byte ordering

`/gtfs_agencies/list` orders by `agency_name` through the database's glibc
collation, which compares first ignoring punctuation and whitespace and then in
full. A byte comparison puts `"ירושלים - עיסאוויה…"` before `"ירושלים-אבו-תור…"`;
production puts it after `"ירושלים-דרום…"`. ClickHouse's `COLLATE 'he'` does not
reproduce it either, because ICU treats punctuation as significant by default.

Any client that re-sorts this list locally will disagree with the API.

---

## 10. Three bugs in the GTFS loader, found by reproducing it

Each is small, each is in the API's output today, and each is the kind a reimplementation
quietly "fixes" and therefore gets wrong. Measured on 2026-05-20.

**An empty `route_short_name` is stored as the string `"NaN"`.** The feed leaves it blank for
trains and a few bus lines; pandas reads a blank CSV field as a float NaN, and SQLAlchemy
writes its `str()` into a text column. **596 of 6,423 routes** that day carry the literal
`NaN`, and the API returns it.

**A stop gets one row per `stop_id` instead of one per `stop_code`.** In
`open_bus_gtfs_etl/load_stops_to_db.py` the cache `gtfs_stops_by_code` is read in both
branches but only ever written in the `if`, never in the `else` that creates a stop. So the
second feed row carrying a code already created in this run misses the cache and inserts
again. On 2026-05-20 that is **30,417 rows for 29,866 distinct codes** — stop code 2463 has
five identical rows, same name, same city, same coordinates. `/gtfs_stops/list` returns them
all.

**A `shape_dist_traveled` of zero is stored as NULL.** The guard is
`if not row['shape_dist_traveled'] or numpy.isnan(...)`, and `not 0.0` is true in Python, so a
genuine zero takes the same path as a missing value. **6,827 of 242,921** stop times.

None of the three loses data, and all three are easy to fix. They are listed because anyone
rebuilding this will produce different output without them, and will be right to wonder which
side is wrong.

## 11. A GTFS date is not a function of one feed

Production's rows for a past date accumulate across feed versions, because the loader upserts
and never deletes. Its `gtfs_ride` rows for 2026-05-20 carry two different feed suffixes:
**115,060 from the feed published 2026-05-19 and 6,838 from 2026-05-20's**. Each ETL run left
its layer.

That makes a past date unreproducible from the archive alone — not wrong, but worth knowing
before anyone tries to verify a rebuild against it. Rides present in both do match exactly:
7,423 of them, with identical `start_time`, `end_time` and route, and 242,921 ride stops with
every field identical.

## 12. The API does not compress anything

Measured against production on 2026-11-04, asking for compression explicitly:

```
$ curl -H 'Accept-Encoding: gzip, deflate, br' \
    '.../siri_vehicle_locations/list?limit=500&recorded_at_time_from=...'
content-type: application/json
content-length: 363063
```

No `content-encoding`, no `vary`. **363,063 bytes where gzip gives 32,719 — 11.1x.** JSON of
repeated keys and numeric strings is close to the best case for a compressor, and this is the
map's own endpoint, requested continuously by every open tab.

The same gap appeared in this reimplementation, with a sharper edge: Node's `res.end(text)`
sends `Transfer-Encoding: chunked`, and **CloudFront's automatic compression only applies to
an origin response that carries `Content-Length`**. A CDN with `compress = true` would
therefore have shipped every byte uncompressed and looked correctly configured. Fixed in
`api/src/server.ts` by compressing at the origin and always setting the length.

It costs nothing to fix on either side, and it is the cheapest tenfold improvement available
anywhere in the stack --- in egress, in latency, and on mobile data.

---

## 13. Twenty months of missing ride durations also zeroed the dashboard's actual-ride counts

`siri_ride.duration_minutes` is written by `stride-etl-siri-add-ride-durations`, which the
project describes as running every hour and repopulating all ride durations. Sampled one hour
per date against live production on 2026-11-05, 100 rides each:

| Date | Rides with a duration |
| --- | --- |
| 2024-09-01 | 100 / 100 |
| 2024-11-01 | **0 / 100** |
| 2025-06-01 | **0 / 200** |
| 2026-06-01 | **0 / 200** |
| 2026-07-01 | 99 / 100 |
| 2026-11-01 | 200 / 200 |

The dump dates the decline precisely, by month of 2024: 2,929,417 of 2,929,417 rides in
September, 609,298 of 2,485,854 in October, 147,693 of 2,785,949 in November, and **7 of
3,086,370 in December**. All of 2025 is zero.

It will not recover on its own. `main(num_days=4)` processes a trailing four-day window, and
the `UPDATE` is gated on `updated_duration_minutes IS NULL`, so a ride older than the window
is never reconsidered. The hourly task keeps today's data correct and cannot reach back.

**Production recovered going forward on 2026-09-08, and the hole stayed.** Measured against
live production on 2026-11-06, one 30-minute window of `/siri_rides/list` per date, 200 rides
each:

| Date | With a duration | Linked to a GTFS ride |
| --- | --- | --- |
| 2025-03-10 | **0 / 200** | **0 / 200** |
| 2026-05-25 | **0 / 200** | **0 / 200** |
| 2026-09-15 | 200 / 200 | 199 / 200 |
| 2026-11-03 | 200 / 200 | 200 / 200 |

So whatever was fixed was fixed for new data only, exactly as the trailing window predicts.

**The consequence is larger than a missing column, and it is the reason this was found.**
Every `UPDATE` in `open-bus-stride-etl`'s `siri/update_rides_gtfs.py` — all four of them — is
gated on `siri_ride.updated_duration_minutes is not null`. No duration therefore means no
`scheduled_time_gtfs_ride_id`, and `gtfs_rides_agg_by_hour` counts actual rides as
`count(*) filter (WHERE sr.scheduled_time_gtfs_ride_id is not null)`. The whole chain is one
gate deep, and `/gtfs_rides_agg/group_by` is what the dashboard's execution charts read.

Measured against live production on 2026-11-06, summed over all operators for one day:

| Date | Planned rides | Actual rides |
| --- | --- | --- |
| 2024-08-14 | 119,923 | 114,210 |
| 2025-03-10 | 119,622 | **0** |
| 2025-11-10 | 122,264 | **0** |
| 2026-05-25 | 121,671 | **0** |
| 2026-08-25 | 119,615 | **0** |
| 2026-09-08 | 123,331 | 1,240 |
| 2026-09-10 | 124,359 | 116,613 |
| 2026-11-03 | 124,220 | 118,404 |

For roughly twenty months the dashboard answered "zero buses ran" for every operator on every
day, and it reads as data rather than as an outage. Nothing in the API distinguishes the two.

**A second, separate defect in the same file.** `SET_DURATION_OLD_TRIPS` writes
`duration_minutes = 0` for any ride still without locations two days on, which makes "no data"
indistinguishable from "a ride that lasted zero minutes". Measured in production: 5 of 200
sampled rides on 2024-06-01, so 2.5% of a day where coverage is otherwise complete.

Nothing here is a heuristic — it is one `UPDATE` with window functions over each ride's own
locations, three clock rules, and two `NOW()` bookkeeping columns. Reproducing it is an
aggregation, measured at 0.087 s for a whole day, which is why this implementation computes it
for the whole history instead of inheriting the gap.

---

## 14. The ministry reports buses from the future, and the API serves them

`max(recorded_at_time)` over this database is **2038-01-14 17:22:21**. Measured on the rows
ingested since 2026-11-01: **53,976 of 17,034,687 readings, 0.32%, carry a timestamp later than
the moment they were read.**

They are not clustered at one bad value, which is what a single broken device would look like.
By year, for those rows:

| Year stamped | Readings |
| --- | --- |
| 2027 | 11,026 |
| 2028 | 17,525 |
| 2029 | 11,346 |
| 2030 | 839 |
| 2031 | 1,840 |
| 2032 | 881 |
| 2033 | 5,316 |
| 2034 | 4,630 |
| 2035 | 208 |
| 2036 | 871 |
| 2037 | 359 |
| 2038 | 77 |

**It is in the ministry's own archive, not in the parsing.** The obvious suspicion is that
`parseDateTime32BestEffort` invented these out of a malformed string, so one was traced back to
the source file. Snapshot `2026/06/08/16/46`, vehicle `38552002`, read straight from
`s3://openbus-stride-public` with every field as a string:

```
raw_recorded_at_time:        2029-01-01T17:02:01+02:00
data_frame_ref:              2026-06-08
origin_aimed_departure_time: 2026-06-08T19:40:00+03:00
```

The ride's service date is 2026-06-08 and its aimed departure is that evening. The reading says
it was recorded on 1 January 2029. `2029-01-01T17:02:01+02:00` is `2029-01-01 15:02:01` UTC,
which is exactly what this database stores — so the value is carried faithfully from the source
and the defect is upstream of everything we built.

Two details that point at a cause without settling it. The bogus record carries `+02:00`, which
is Israel's winter offset, while the same vehicle's good readings in the same June snapshot
carry `+03:00` — consistent with a device whose clock has been reset rather than skewed. And
the same `(vehicle, bogus timestamp)` pair repeats across four consecutive snapshots, so it is
a device that stayed wrong, not a transmission glitch.

**Why it matters beyond being untidy.** It is served. `/siri_vehicle_locations/list` with no
upper bound returns these rows, which is how this was found: a sample for a compression
measurement came back with readings in 2035 and the ratio made no sense. Anything that takes
`max(recorded_at_time)` as "how fresh is the data" gets 2038, and anything that plots a vehicle
over time gets a track that leaves the chart. The status query this implementation publishes
deliberately uses the ingested snapshot id instead, because that comes from the archive's own
path and cannot be a bus's opinion about the date.

A bounded `max(recorded_at_time) WHERE recorded_at_time <= now()` returns the right answer and
was measured at 5.9 s against 105 ms, because the bound stops the index being read from the
tail. That is the cost of working around it rather than fixing it at the source.

---

## Reporting these

These are observations from outside, and some may have a reason we cannot see
from here. The intent is to open them as issues on the relevant `hasadna`
repositories, one each, with the measurement attached — not to assert they are
all defects.
