# Roadmap

Where this is, what is left, and what was deliberately left out. Status as of 2026-11-03.

Cost analysis is kept out of this repository — see the note at the end.

## Acceptance criteria

Three, set at the start, unchanged since:

1. **Every API endpoint preserves its behaviour**, proven by comparison against production.
   This is the gate, not an aspiration.
2. **A simple implementation.** No complexity beyond what the problem demands. Every
   component justifies its existence.
3. **Modern infrastructure**: test coverage, infrastructure as code, CI/CD in GitHub Actions.

## Stages

| | Stage | Gate | Status |
| --- | --- | --- | --- |
| 1 | Run the org's existing ClickHouse stack | migrations apply, dbt models build, `ALIAS` columns return correct values | **done** |
| 2 | GTFS ingest — the blocking gap | GTFS tables in ClickHouse, both enrichment macros off `postgresql()` | **partly** |
| 3 | The remaining ETL processes | no Airflow, `system.view_refreshes` clean for 24 h | not started |
| 4 | The TypeScript API | 27 of 27 endpoints identical to production | **13 of 27** |
| 5 | Sizing and deployment | measured resource figures under continuous ingest | not started |

### Stage 1 — done

The six `goose` migrations apply and the five dbt models build against a local ClickHouse.
Three things it turned up:

- The POC **does not stand on its own.** Both enrichment macros
  (`siri_ride_gtfs_ride_query.sql`, `siri_ride_stop_gtfs_stop_query.sql`) read live GTFS out
  of PostgreSQL through the `postgresql()` table function. A full migration has to build GTFS
  ingest regardless, which is why that is stage 2 and not an afterthought.
- The identities that make `siri_ride_stop` and `gtfs_ride_stop` enormous in PostgreSQL are
  already declared as zero-storage `ALIAS` columns in the org's own schema.
- The enrichment computations measure at 26–87 ms. The work itself is not the expensive part.

### Stage 2 — in progress

The source is public and current: `s3://openbus-stride-public/gtfs_archive/YYYY/MM/DD/`,
updated daily. `israel-public-transportation.zip` is 170 MB/day and holds a 968 MB
`stop_times.txt` uncompressed. ClickHouse cannot read a multi-file zip, so the step is curl,
unzip, `INSERT … FORMAT CSVWithNames` — about fifteen lines of shell.

**A modelling hypothesis that turned out to be wrong, and is recorded because the conclusion
survived it.** GTFS defines `stop_times` once per feed version per trip, not per date, so the
guess was that the 4.11 billion `gtfs_ride_stop` rows could be expanded at read time against
`calendar.txt`. Measured: 1595 days × 18.28M `stop_times` rows is **29 billion rows**, seven
times worse than storing them. PostgreSQL's data model is right; it simply pays about 50× in
bytes for it. Materialising the expansion is both cheaper and simpler than query-time
calendar expansion, which would also have to re-derive service dates on every request.

### Stage 4 — 13 of 27

| | Count |
| --- | --- |
| Matching production, byte for byte | **13** |
| Registered, not yet verified | 7 |
| Not written | 7 |

The 13 are verified by 22 differential cases comparing normalised JSON — not status codes —
against the live production API. 35 unit tests cover SQL generation and need no database.

**What is left, and why each one is not just more of the same:**

- `/route_timetable/list` and `/stop_arrivals/list` fit the existing builder. Both use
  `skip_order_by`. Straightforward.
- Five endpoints need a second mechanism, because they are hand-written aggregate SQL rather
  than filter-and-sort over one table: `/gtfs_agencies/list` (a `GROUP BY` over `gtfs_route`
  with a fixed sort and no `order_by` parameter at all), `/gtfs_rides_agg/list`,
  `/gtfs_rides_agg/group_by`, `/rides_execution/list`, and
  `/siri_velocity_aggregation/siri_velocity_aggregation`.
- `/siri_ride_stops/list` is registered but needs the two-stage query shape below.

**The real blocker is the sort key, not the row count.** `/siri_ride_stops/list` joins seven
tables. A naive translation returns correct rows in 48.8 s, and the cause is not any single
join:

| Finding | Measured |
| --- | --- |
| ClickHouse hashes the right side of a join whole; there is no nested-loop-on-index | rewriting the join as an `IN` subquery: **>60 s → 0.059 s** |
| Every join needs that rewrite, not just the huge ones | `gtfs_ride` (115M) and `gtfs_stop` (35M) hashed whole blew a 4 GB limit; each table alone is 0.002–0.004 s |
| A `bloom_filter` skip index is the wrong tool for an uncorrelated foreign key | correlation of `id` to `gtfs_ride_id` is **−0.05**; no index 4.35 s → `bloom_filter(0.0001)` 1.22 s → **projection 0.015 s** |
| A CTE is inlined, not materialised | the 48.8 s was one 5.23 s base query running about eight times; two round trips make stage 2 **0.018 s** |

So: a builder that resolves base rows first and then fetches related tables by literal id
list, plus a projection on each table whose foreign key is filtered but not sorted. Both are
specified; neither is built.

### Stage 5 — not started

Measure RSS and CPU under continuous ingest plus refresh — the figure that matters is the
steady state, not a single query. Then deploy via the Terraform module in `infra/`.

## Deliberately out of scope

Criterion 2 is a constraint with teeth. Each of these was considered and dropped:

- **dbt.** In the existing repo it templates SQL and passes date parameters for backfills.
  That requires a Python toolchain with `uv` and a `profiles.yml` to get Jinja templating
  over five models. The simpler substitute: `goose` for migrations (already in use),
  refreshable materialized views for the steady state, and one parameterised SQL file for
  backfill invoked through `clickhouse-client --param_`. One component fewer, no capability
  lost.
- **A scheduler, a message queue, a cache layer.** ClickHouse schedules; a CDN caches. Any
  additional layer has to justify itself with a measurement.
- **An ORM.** 27 GET endpoints with filtering and sorting are query construction, not an
  object model.
- **Rewriting the SIRI collector.** It works and it is the source of the data. Rewriting it
  is risk without return. Python stays exactly there.

## If this goes anywhere

The code splits back into the org's repositories — `db/` and ingest into
`open-bus-stride-clickhouse`, `api/` into `open-bus-stride-api`, `infra/` into `hasadna-iac`.
The directory boundaries are kept clean from day one so that split is mechanical rather than
a rewrite.

## Known gaps, stated rather than buried

- **PostgreSQL wins one query.** A selective `line_ref` + bounding-box filter is 0.017 s
  against 0.063–0.090 s, because B-tree indexes on `lon`/`lat` are the right tool. Closing it
  needs skip indexes. Not done.
- **Projections are not in the 163 GiB.** Two of them take the honest total to ~219 GiB.
  Quote 219, not 163.
- **The `siri_ride_stop` projection is predicted, not measured.** The 0.015 s figure above is
  measured on `gtfs_ride_stop`; the second one is inferred from it.
- **Neither `gtfs_ride_stop` nor `siri_ride_stop` has an ETL** that would keep it current.
  They are loaded and measured; they are not maintained.
- **The public dump is 4.6 months old**, which bounds every differential test case.

## On cost

Every storage, RAM and throughput measurement needed to build a cost model is in
[docs/BENCHMARKS.md](docs/BENCHMARKS.md). The cost model itself is not, and neither is what
the project pays today: spend figures belong to the project's maintainers and are theirs to
publish or not. The technical case stands on the measurements either way.
