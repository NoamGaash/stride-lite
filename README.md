# stride-lite

[עברית](README.he.md) · **[Who decided what](#who-decided-what)** · [Cost, performance, tradeoffs](docs/DEPLOYMENT.md) · [Roadmap](ROADMAP.md) · [Measurements](docs/BENCHMARKS.md) · [Run it locally](docs/LOCAL-DB.md)

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

## Who decided what

This repository is one person's brief and an AI agent's execution of it. Those are not the
same thing, and a reader deciding whether to trust a number here needs to know which is
which. Three lists follow: what was asked for, what the agent chose on its own, and what it
actually did.

### What [@NoamGaash](https://github.com/NoamGaash) asked for

**The goal.** Rebuild the Open Bus Stride backend from scratch on ClickHouse, run it locally,
measure what it really costs in resources, price it on AWS, and — if it comes in under
**$150/month** — propose it as a replacement for the current Kamatera infrastructure.

**Definition of done.** An API serving data from a local database and returning the same
results as production.

**Three acceptance criteria**, stated as conditions and not aspirations:

1. **Every API endpoint preserves its behaviour**, proven by comparison against production.
2. **A simple implementation.** No complexity beyond what the problem requires.
3. **Modern infrastructure**: test coverage, infrastructure as code, CI/CD on GitHub Actions.

**Constraints added along the way**, each of which changed the work:

| Constraint | What it ruled out |
| --- | --- |
| Public-transport data must be **byte-for-byte identical**; our own internal ids may change | Settles the id question below — surrogate keys are ours to choose, MOT data is not |
| **Plug and play** — one command, not a mechanism to operate | Multi-step bring-up instructions as the final answer |
| **Do not load the machine.** It is a volunteer's workstation and their livelihood runs on it | Any default that assumes a dedicated server |
| **Do not over-simplify if it costs performance.** "Simple" is not a licence to be slow | Dropping indexes, projections or denormalisation to shorten the code |
| What the project pays today is **private**; estimates from public rates are fine | Any comparison quoting the real invoice |
| A **public repository**, no secrets, Hebrew and English documentation | — |
| **AI agents must identify themselves** when acting in the project (the repo's own rule) | — |

### What the agent interpreted, chose, or assumed

None of the following was requested. Each is a judgement call, and each could be wrong.

| Decision | Why | What would overturn it |
| --- | --- | --- |
| **ClickHouse**, single node | The workload is append-only analytics over one wide fact table | A write pattern needing real transactions |
| **"Same results" read as byte-identical JSON**, not matching status codes | A weaker reading makes criterion 1 untestable | — |
| **TypeScript** for the API | The generated client and the frontend are already TypeScript | — |
| **Refreshable materialized views as the scheduler** | `system.view_refreshes` already reports what Airflow is deployed to report | Work that genuinely needs a DAG, not a cadence |
| **No dbt, scheduler, queue, cache or ORM** | Criterion 2 — each would have to earn its place | A measurement showing one is needed |
| **Terraform**, as a module beside `hasadna-iac`'s existing ones | Continuation rather than a parallel toolchain | — |
| **The stale dump's window is the test boundary** | Every differential case must sit inside it or fail for a reason that is not a bug | Fresh data, which needs the unbuilt enrichment |
| **`m7g.large` + 300 GB gp3** for the estimate | Peak measured query memory was ≤25 MB, so 8 GB is not optimistic | A sustained measurement under continuous ingest, which has not been run |

### What the agent actually did

Measured, in a session, and reproducible by [docs/LOCAL-DB.md](docs/LOCAL-DB.md):

- Loaded the full 13,728,053,041-row public dump and measured storage per table and per engine.
- Wrote the API: 20 of 27 endpoints registered, **13 verified byte-identical** across 22 cases.
- Built the continuous SIRI ingest from S3 — three SQL objects, no scheduler.
- Wrote the CI, the Terraform module, and 35 unit tests on SQL generation.
- Capped its own work on the machine: 6 of 24 cores, `nice 19`, and ClickHouse's own
  bandwidth and memory ceilings.

**Not done, and material to criterion 1:**

- **27 of 27 is not met.** 13 verified, 7 registered but never compared against production,
  7 not written at all. The agent spent the time on measurement, the repository and the
  ingest instead; that was its own choice and it left the stated criterion unmet.
- **The enrichment is not built**, so the ingest and the API are not joined up.
- **The daily GTFS refresh is not built.**

## Quickstart

```bash
curl https://clickhouse.com/ | sh && ./clickhouse server --daemon
export CH_CLIENT="./clickhouse client"
./scripts/apply-schema.sh                                  # 16 tables
CH_DB=stride ./ingest/backfill.sh 2026 11 03               # a day of live SIRI from S3, ~2 min
./clickhouse client --database stride --multiquery < ingest/siri.sql   # continuous ingest, no scheduler
cd api && npm ci && CH_DB=stride npm start                 # API on :8080
```

No Docker, no root, no credentials — the data is public. The full reproduction, including the
13.7-billion-row dump, is in [docs/LOCAL-DB.md](docs/LOCAL-DB.md); cost and cloud resources
are in [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

## The three numbers that motivated this

Measured on the public 2026-06-14 production dump — all 16 tables, 13,728,053,041 rows,
loaded and counted, not extrapolated.

| | PostgreSQL today | ClickHouse |
| --- | --- | --- |
| `siri_vehicle_location` (6.5 billion rows) | **1.34 TB** | **111.52 GiB** |
| The entire database | ~692 GiB of data + ~760 GB of indexes | **163.22 GiB** |
| Growth per year | +307 GB | **+36 GB** |
| Estimated AWS bill | — | **~$96/month** |

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

**13 of the 27 endpoints are verified byte-identical to production**, over 22 differential
test cases. Not "same status code" — the same JSON.

**The acceptance criterion is 27 of 27, and it is not met.** The 22 cases cover 13
endpoints only; the other 14 are either unverified or unwritten. See
[Who decided what](#who-decided-what) for whose call that was.

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

```mermaid
flowchart TB
    MOT["Ministry of Transport<br/>SIRI feed, real time"]
    MOTG["Ministry of Transport<br/>GTFS feed, daily"]

    MOT --> REQ["open-bus-siri-requester<br/>runs in production today"]
    MOTG --> REQG["gtfs-etl-download-upload<br/>runs in production today"]

    REQ --> S3S["s3://openbus-stride-public/stride-siri-requester/<br/>YYYY/MM/DD/HH/MM.br &middot; public, no credentials<br/><b>fresh</b>"]
    REQG --> S3G["s3://openbus-stride-public/gtfs_archive/<br/>YYYY/MM/DD/israel-public-transportation.zip &middot; 170 MB a day<br/><b>fresh</b>"]

    DUMP["s3://openbus-stride-public/stride_db.sql.zst<br/>pg_dump of production, 154 GB compressed<br/><b>stale: Last-Modified 2026-06-14</b>"]

    subgraph CH["ClickHouse &mdash; one node, no scheduler, no Airflow"]
        direction TB
        RAW["siri_vehicle_location_raw<br/>the feed as it arrives<br/>every field a string, no foreign keys"]
        TYPED["siri_vehicle_location + 15 tables<br/>what the API serves<br/>typed, integer foreign keys"]
        GTFS["gtfs_route &middot; gtfs_stop &middot; gtfs_ride<br/>loaded from the dump, not yet refreshed"]
    end

    S3S -->|"ingest/siri.sql<br/>REFRESH EVERY 1 MINUTE<br/>1 h of snapshots in 5-6 s"| RAW
    DUMP -->|"scripts/load-from-dump.sh<br/>one-time bootstrap<br/>13.7 b rows"| TYPED
    DUMP --> GTFS
    S3G -.->|"daily GTFS refresh<br/>NOT BUILT"| GTFS
    RAW -.->|"enrichment<br/>NOT BUILT"| TYPED

    TYPED --> API["stride-lite API<br/>TypeScript, 20 of 27 endpoints"]
    GTFS --> API
    API --> FE["open-bus-map-search<br/>and public API consumers"]

    classDef ext fill:#e2e8f0,stroke:#475569,color:#0f172a
    classDef live fill:#dbeafe,stroke:#2563eb,color:#0f172a
    classDef stale fill:#fef3c7,stroke:#d97706,color:#0f172a
    classDef done fill:#dcfce7,stroke:#16a34a,color:#0f172a
    classDef todo fill:#fee2e2,stroke:#dc2626,color:#0f172a

    class MOT,MOTG,REQ,REQG,FE ext
    class S3S,S3G live
    class DUMP stale
    class RAW,TYPED,GTFS,API done
```

**Solid arrows are built and measured; dashed arrows are not built.** Three data sources, and
the difference between them matters:

- **The requester archives are live.** `stride-siri-requester/` gets a snapshot roughly every
  minute and `gtfs_archive/` a feed every day, both written by processes already running in
  production, both public and readable with `NOSIGN`. This is what the continuous ingest reads.
- **The database backup is not live.** It is a one-time bootstrap for four years of history,
  and it stopped being written on 2026-06-14.
- So the raw table tracks today while the API's tables stop at the dump — because the
  enrichment that would connect them is the missing arrow.

All three paths were checked against S3 on 2026-11-04: the dump still answers
`Last-Modified: Sun, 14 Jun 2026`, `gtfs_archive/2026/11/03/` holds that day's feed, and
`stride-siri-requester/2026/11/04/` was already on hour 05.

| Layer | Technology | New code |
| --- | --- | --- |
| SIRI collection | the existing `open-bus-siri-requester`, unchanged | none |
| SIRI ingest → raw table | ClickHouse `s3()` + refreshable materialized view | [`ingest/siri.sql`](ingest/siri.sql) — 3 objects, no scheduler |
| raw → the API's typed tables | ClickHouse materialized views | **not built** |
| GTFS ingest | shell: curl, unzip, `clickhouse-client` | ~15 lines |
| Enrichment | ClickHouse materialized views | **none** |
| Scheduling | ClickHouse `REFRESH EVERY` | **none** |
| Monitoring | `system.view_refreshes` | **none** |
| API | TypeScript | the only service |
| Infrastructure | Terraform | — |

**The ingest loop is built and running**, which is the part the org's own `PLAN.md` still
lists as open ("keep track of ingested siri snapshots", "ingest new snapshots as they arrive",
*probably via Airflow*). It is three objects in one SQL file and no Airflow: a
`ReplacingMergeTree` of snapshot ids, an incremental view that maintains it from the data
itself, and two refreshable views that read S3 and skip what is already in. Measured against
the live archive: **one hour of snapshots ingests in 5–6 s, and re-running an already-loaded
hour writes 0 rows in 0 s.**

**What it does not yet do:** it lands rows in `siri_vehicle_location_raw`, which is the MOT
feed as it arrives — every field a string, no foreign keys. The API's `siri_vehicle_location`
is typed and joined by integer id, and today it comes from the dump. Deriving the second from
the first is the enrichment, and that is **not built**, so the ingest loop is real but the
pipeline is not yet end to end.

`system.view_refreshes` reports `status`, `next_refresh_time`,
`written_rows` and `exception` — the visibility Airflow is there to provide, inside the
database.

**TypeScript for the API on purpose**, not by taste: the generated client
`@hasadna/open-bus-api-client` and the [frontend](https://github.com/hasadna/open-bus-map-search)
are already TypeScript, so types are shared end to end.

**Deliberately absent:** dbt, a scheduler, a message queue, a cache layer, an ORM. 27 GET
endpoints with filters and sorting are query construction, not an object model. Each omission
is argued in [ROADMAP.md](ROADMAP.md).

## Layout

```
db/schema.sql     the 16 tables, dumped from the running instance
ingest/           siri.sql (continuous, 3 objects), backfill.sh (history)
api/              TypeScript service — src/{sql,registry,server,ch}.ts
infra/main.tf     Terraform module
scripts/          apply-schema.sh, load-from-dump.sh
docs/             BENCHMARKS.md (the full measured report), LOCAL-DB.md
```

If this goes anywhere, the pieces split back into the org's repos — `db/` and ingest into
`open-bus-stride-clickhouse`, `api/` into `open-bus-stride-api`, `infra/` into `hasadna-iac`.
The directory boundaries are kept clean from day one so that split is mechanical.

## Honest caveats

- **The ingest and the API are not joined up yet.** New data lands in a raw table; the API
  reads typed tables loaded from the dump. The enrichment between them is unbuilt.
- The public dump is **4.6 months old** — `Last-Modified: 2026-06-14`, data ending
  2026-05-29. Every differential test case has to stay inside that window, which is the
  single biggest constraint on this work.
- **PostgreSQL wins one query** — a selective `line_ref` + bounding-box filter, 0.017 s
  against 0.063–0.090 s. B-tree indexes on `lon`/`lat` are the right tool there, and closing
  the gap with skip indexes is work not yet done.
- The AWS estimate's one unquantified risk is **egress above CloudFront's free 1 TB**,
  which needs a real traffic figure before anyone relies on the ~$96. The estimate itself is
  built from published AWS rates; what the project pays today was reported privately and is
  not in this repository.
- **Projections are not in the 163 GiB.** Two of them take the honest total to ~219 GiB.
- This repository does not answer the questions that actually decide a migration: who
  maintains it, what happens at 3 a.m., and what breaks in a provider move. Those are the
  maintainers' calls, and measurements do not settle them.

## Licence

MIT. The data is public, published by the Israeli Ministry of Transport and collected by the
[Public Knowledge Workshop](https://www.hasadna.org.il/).
