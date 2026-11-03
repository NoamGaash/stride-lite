# stride-lite

[עברית](README.he.md) · [Roadmap](ROADMAP.md) · [Measurements](docs/BENCHMARKS.md) · [Run it locally](docs/LOCAL-DB.md)

A from-scratch reimplementation of the [Open Bus Stride](https://github.com/hasadna/open-bus-stride-api)
backend on ClickHouse. Same API contract, byte for byte; a fraction of the storage; no
Airflow.

This is an experiment, not a proposal to merge. It exists to answer one question with
numbers instead of opinions: **what would the Israeli public-transport data backend cost and
look like if it were built today?**

> 🤖 Most of the work in this repository was done by Claude (an AI agent) working with
> [@NoamGaash](https://github.com/NoamGaash). Every number below was measured in a session
> and is reproducible by the instructions in [docs/LOCAL-DB.md](docs/LOCAL-DB.md); nothing
> here is quoted from memory.

## The three numbers that motivated this

Measured on the public 2026-06-14 production dump — all 16 tables, 13,728,053,041 rows,
loaded and counted, not extrapolated.

| | PostgreSQL today | ClickHouse |
| --- | --- | --- |
| `siri_vehicle_location` (6.5 billion rows) | **1.34 TB** | **111.52 GiB** |
| The entire database | ~692 GiB of data + ~760 GB of indexes | **163.22 GiB** |
| Growth per year | +307 GB | **+36 GB** |
| Estimated AWS bill | — | **~$102/month** |

Three findings behind them:

1. **Indexes are 55% of PostgreSQL's footprint** — 93 bytes of data against 107.6 bytes of
   index per row. A column store does not pay that.
2. **Nearly half the database is ETL output.** `siri_ride_stop` (2.80 billion) and
   `gtfs_ride_stop` (4.11 billion) exist only as precomputed results. In ClickHouse most of
   those relationships are `ALIAS` columns that cost zero bytes.
3. **The expensive part is the orchestration, not the data.** The recurring ETL work measures
   at about one second per hour, while the Airflow scheduler alone requests 20–25 GB of RAM
   and 2 cores. ClickHouse's `REFRESH EVERY` schedules the same work inside the database and
   reports it in `system.view_refreshes`.

## Where it stands

**22 of 22 differential test cases across 13 endpoints are byte-identical to production.**
Not "same status code" — the same JSON.

| | |
| --- | --- |
| Endpoints matching production | 13 of 27 |
| Endpoints registered but not yet verified | 7 |
| Endpoints not written | 7 (five need hand-written aggregate SQL) |
| Unit tests on SQL generation | 35, passing, no database required |
| Lines of API code | 1,105 TypeScript |

The acceptance criterion is 27 of 27. [ROADMAP.md](ROADMAP.md) says what is left.

### What the contract turned out to be

Reimplementing an API is mostly discovering what it actually promises. Four things only the
source and live probes reveal, each of which silently breaks a client if you get it wrong:

- **Row ordering has four distinct shapes**, depending on how each handler declares the
  `order_by` parameter — not one default. `/gtfs_stops/list` ignores `order_by` entirely.
- **Two different datetime contracts.** A date-granular parameter takes a bare calendar day;
  an instant-granular one *requires* a timezone offset and converts to UTC rather than
  dropping it. Sending a bare date to the latter is a 422; omitting the offset is a 500.
- **Microsecond precision is per column**, not global. Getting this right rather than
  blanket-upgrading saved about 26 GB on the largest table.
- `/gtfs_rides/list` does not return within production's timeout for a plain date-range
  query, so that shape cannot serve as a differential baseline.

## Architecture

| Layer | Technology | New code |
| --- | --- | --- |
| SIRI collection | the existing `open-bus-siri-requester`, unchanged | none |
| SIRI ingest | ClickHouse `s3()` + refreshable materialized view | **none** |
| GTFS ingest | shell: curl, unzip, `clickhouse-client` | ~15 lines |
| Enrichment | ClickHouse materialized views | **none** |
| Scheduling | ClickHouse `REFRESH EVERY` | **none** |
| Monitoring | `system.view_refreshes` | **none** |
| API | TypeScript | the only service |
| Infrastructure | Terraform | — |

Both load-bearing claims were tested, not assumed: ClickHouse read 426,476 rows from an hour
of public S3 snapshots in 2.087 s with no application code, and `REFRESH EVERY 1 MINUTE`
reports `status`, `next_refresh_time`, `exception`, `retry` and `progress` — the visibility
Airflow is there to provide, inside the database.

**TypeScript for the API on purpose**, not by taste: the generated client
`@hasadna/open-bus-api-client` and the [frontend](https://github.com/hasadna/open-bus-map-search)
are already TypeScript, so types are shared end to end.

**Deliberately absent:** dbt, a scheduler, a message queue, a cache layer, an ORM. 27 GET
endpoints with filters and sorting are query construction, not an object model. Each omission
is argued in [ROADMAP.md](ROADMAP.md).

## Layout

```
db/schema.sql     the 16 tables, dumped from the running instance
api/              TypeScript service — src/{sql,registry,server,ch}.ts
infra/main.tf     Terraform module
scripts/          apply-schema.sh, load-from-dump.sh
docs/             BENCHMARKS.md (the full measured report), LOCAL-DB.md
```

If this goes anywhere, the pieces split back into the org's repos — `db/` and ingest into
`open-bus-stride-clickhouse`, `api/` into `open-bus-stride-api`, `infra/` into `hasadna-iac`.
The directory boundaries are kept clean from day one so that split is mechanical.

## Honest caveats

- The public dump is **4.6 months old** — `Last-Modified: 2026-06-14`, data ending
  2026-05-29. Every differential test case has to stay inside that window, which is the
  single biggest constraint on this work.
- **PostgreSQL wins one query** — a selective `line_ref` + bounding-box filter, 0.017 s
  against 0.063–0.090 s. B-tree indexes on `lon`/`lat` are the right tool there, and closing
  the gap with skip indexes is work not yet done.
- The AWS estimate's one unquantified risk is **egress above CloudFront's free 1 TB**,
  which needs a real traffic figure before anyone relies on the ~$102. The estimate itself is
  built from published AWS rates; what the project pays today was reported privately and is
  not in this repository.
- **Projections are not in the 163 GiB.** Two of them take the honest total to ~219 GiB.
- This repository does not answer the questions that actually decide a migration: who
  maintains it, what happens at 3 a.m., and what breaks in a provider move. Those are the
  maintainers' calls, and measurements do not settle them.

## Licence

MIT. The data is public, published by the Israeli Ministry of Transport and collected by the
[Public Knowledge Workshop](https://www.hasadna.org.il/).
