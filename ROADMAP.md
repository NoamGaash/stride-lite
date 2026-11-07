# Roadmap

[עברית](ROADMAP.he.md)

Where this is, what is left, and what was deliberately left out. Status as of 2026-11-05.

Cost estimates are built from published AWS and Kamatera rates and are in
[docs/BENCHMARKS.md](docs/BENCHMARKS.md); what the project pays today is not — see the note
at the end.

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
| 2 | GTFS ingest — the blocking gap | GTFS tables in ClickHouse, both enrichment macros off `postgresql()` | **done** |
| 3 | The remaining ETL processes | no Airflow, `system.view_refreshes` clean for 24 h | **done**, except a 24 h unattended run |
| 4 | The TypeScript API | 27 of 27 endpoints identical to production | **done** |
| 5 | Pricing and deployment | measured resources, priced under the $150/month target | **priced: $3.24/day, $98/month.** Not deployed |

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

### Stage 2 — done

The source is public and current: `s3://openbus-stride-public/gtfs_archive/YYYY/MM/DD/`,
updated daily. ClickHouse cannot read a multi-file zip, so [`ingest/gtfs.sh`](ingest/gtfs.sh)
is curl, unzip and `INSERT … FORMAT CSVWithNames`, and
[`ingest/gtfs.sql`](ingest/gtfs.sql) derives the five GTFS tables from the staged text.
**One day in 35 s.** It is the only step in the system that needs a scheduler.

Verified field by field against production on 2026-05-20, a date both databases hold:

| | |
| --- | --- |
| Routes | **6,423 vs 6,423**, every field identical |
| Stops | **30,417 vs 30,417** |
| Rides in common | 7,423, identical `start_time`, `end_time` and route |
| Ride stops in common | **242,921, every field identical** |

Reaching that meant reproducing three upstream bugs rather than fixing them — an empty
`route_short_name` stored as the string `"NaN"`, one stop row per `stop_id` instead of per
`stop_code`, and a `shape_dist_traveled` of zero stored as NULL. They are findings 10 and 11
in [docs/FINDINGS.md](docs/FINDINGS.md), because a migration that silently changes what the
API returns is not a migration.

**A modelling hypothesis that turned out to be wrong, and is recorded because the conclusion
survived it.** GTFS defines `stop_times` once per feed version per trip, not per date, so the
guess was that the 4.11 billion `gtfs_ride_stop` rows could be expanded at read time against
`calendar.txt`. Measured: 1595 days × 18.28M `stop_times` rows is **29 billion rows**, seven
times worse than storing them. PostgreSQL's data model is right; it simply pays about 50× in
bytes for it.

### Stage 4 — done, 27 of 27

| | Count |
| --- | --- |
| Matching production, byte for byte | **27** |
| Differential tests passing | **48**, covering every endpoint in the published spec |

Twenty of them come from the query builder in `api/src/sql.ts`. The other seven are
hand-written aggregate SQL upstream rather than filter-and-sort over one table, so they get a
second mechanism in `api/src/raw.ts`: `/gtfs_agencies/list`, `/gtfs_rides_agg/list`,
`/gtfs_rides_agg/group_by`, `/rides_execution/list`, `/route_timetable/list`,
`/stop_arrivals/list` and `/siri_velocity_aggregation/siri_velocity_aggregation`.

`/gtfs_rides_agg/*` also needed `gtfs_rides_agg_by_hour`, which the dump does not contain
because upstream keeps it as a PostgreSQL materialized view. It is a table here, rebuilt by a
refreshable view: 53,006,384 rows in 181 MiB, 37 s to build.

**The sort key was the real blocker, not the row count.** `/siri_ride_stops/list` joins seven
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

### Stage 3 — SIRI flows end to end

[`ingest/siri.sql`](ingest/siri.sql) closes the gap the org's `PLAN.md` lists as open:
tracking which snapshots are loaded, and ingesting new ones as they arrive. Three objects, no
Airflow. Measured against the live archive: one hour ingests in **5–6 s**, a redundant pass
writes **0 rows in 0 s**, and the partition key lands as `2026/11` as intended.

`ingest/backfill.sh` covers history, with the same dedup filter so it is re-runnable and safe
to run while the live views are up.

[`ingest/enrich.sql`](ingest/enrich.sql) closes the other half. The loop lands rows in
`siri_vehicle_location_raw` — the MOT feed as it arrives, every field a string, no foreign
keys — and six chained refreshable views derive the typed, integer-keyed tables the API reads.
`DEPENDS ON` orders the chain. Measured: six hours and 976,688 readings enrich in **1.6 s**,
a redundant pass writes **0 rows**, and a new snapshot was observed propagating through all
six steps on its own.

**What that unlocks is the differential test itself.** Every case until now had to sit inside
the dump's window, which ends 2026-05-29. With fresh data flowing, the same minute of today
can be compared against production directly. On one such minute:

| | |
| --- | --- |
| Rows returned, production vs ours | **5,765 vs 5,765** |
| Missing / extra readings | **0 / 0** |
| Identical on every transit-data field | **5,685 of 5,746 — 98.94%** |

Two contract rules came out of that comparison, both of which the first attempt got wrong:

- **A ride is identified by `(siri_route_id, journey_ref, vehicle_ref)`**, not by its
  `scheduled_start_time` — those three are already unique over 123,622 rides in a day of the
  dump. The departure time is an attribute taken from the earliest observation. Keying on it
  splits one ride into several whenever the feed revises it: 65 rows in one minute.
- **Production drops readings with no coordinates.** Zero NULL locations in 432,143
  production rows for an hour, against 407 empty ones in 335,227 raw rows.

**The residual, unexplained:** 61 rows in that minute still differ in
`siri_ride__scheduled_start_time`, all for one vehicle whose `journey_ref` is the sentinel
`…-0`. Production reports a departure time that appears nowhere in six hours of the feed, so
the cause is upstream ETL behaviour that has not been read yet. Open.

The **daily GTFS refresh** is now built (stage 2). `gtfs_rides_agg_by_hour` is a table rebuilt
by a refreshable view. Still not built and judged unnecessary until something asks for them:
validate-snapshots, which is a `count` comparison rather than a process, and the packagers.

**Availability is deliberately not engineered**, and that is the project's own call rather than
a shortcut. The Python requesters keep writing to S3 whatever happens here, both loaders are
idempotent, and everything in ClickHouse is derived — so a node that has been dark for a week
catches up in 41 minutes for SIRI and 35 s per missed GTFS day. The database is a cache, not a
system of record. Hence no snapshots, no failover and no health alarms anywhere in `infra/`.
Spend is the one thing that cannot be recovered after the fact, so spend is the one thing
alarmed.

### Stage 5 — priced, not deployed

**$3.24 a day, $98.48 a month in eu-west-1**, on rates taken from AWS's own price list
(effective 2026-11-01) and regenerated by `scripts/fetch-rates.sh` into
[infra/rates.json](infra/rates.json) rather than transcribed. Against the $150 target, and
$76 on a one-year no-upfront reservation.

Compute is **67%** of that and disk 29%; ingest, enrichment, scheduling and the CDN together
are under 0.3%. So the only lever that moves the bill is whether the machine is on: five hours
a week is **$34/month, 83% of it the disk of a switched-off machine.**

`infra/` now provisions a bootable node — `bootstrap.sh` as `user_data` installs ClickHouse,
Node, the schema, the ingest chains and the single GTFS cron entry — plus a budget alarm.

**Two things remain.** RSS and CPU under 24 hours of continuous ingest, which is the figure a
deployment should be sized on. And real traffic volume, the one input the cost model lacks:
the plan is to point the frontend at the deployment for a few days. That measurement has a
trap, documented in [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) — CloudFront's permanent free
tier means the invoice will read $0 for egress, so `scripts/measure-cost.py` reads the bytes
from CloudWatch and prices them instead.

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

- **We duplicated twenty-nine days of our own data, and the gate we built could not see the
  worst of it.** Full inventory, repair and cost in [docs/DATA-REPAIR.md](docs/DATA-REPAIR.md).
  The enrichment mints `id` as `max(id) + row_number()`, which is only a key if one pass runs at
  a time. The race has two failure modes and the first gate caught one: when both passes read
  the same starting max, one id covers two rows; when they read *different* maxima, every id is
  unique and the same reading is simply stored twice. `siri_ride_stop` turned out to be the
  worst-damaged table at **9,161,623 duplicate ids and 1,287,638 duplicate natural keys**, and
  it was the table the gate did not look at. `ingest/verify.sql` now gates ids *and* natural
  keys on three tables plus a duplicate-reading ratio, `ingest/repair-range.sh` re-derives a
  range from the landing table without touching S3, and `enrich-once.sql` refuses to run while
  the chain is enabled — which is the hole that caused all of it.
- **Two short days are the archive's own, not ours.** 2026-08-19 holds 455 of about 1,430
  snapshots and 2026-08-20 holds 1,318 — and the bucket listing returns `KeyCount 455` for the
  19th, so S3 holds 455 too. Neither is a failed download, which is why `snapshots_expected` on
  `/coverage` is documented as a ceiling and not a floor. Friday and Saturday are legitimately a
  half and a sixth of a weekday in *locations*; the snapshot count holds on Shabbat, because the
  collector does not rest even when the buses do.
- **September and October 2026 were never loaded**, and most of November is missing. Measured
  against the bucket listing, finishing the archive is 63 days at 1,427 objects and 0.233 GB
  each: **$1.36 of Hasadna's egress**, once. Re-fetching the six July days and 2026-06-15 that
  no longer have landing rows is a further $0.15.
- **The SIRI↔GTFS link is not implemented.** Not one of the roughly 13.4M rides we ingested
  ourselves carries `scheduled_time_gtfs_ride_id`. The dump has it for 95% of 2024-08 and 50%
  of 2024-09 before collapsing on the same decay as the durations. Durations are now computed,
  which opens the `updated_duration_minutes is not null` gate upstream puts in front of it, but
  the four `UPDATE`s themselves are still not reimplemented.
- **`siri_vehicle_location` has no `PARTITION BY`, and on the evidence it should not.** This was
  an open question and it is now a decision, argued with four measurements in
  [docs/DATA-REPAIR.md](docs/DATA-REPAIR.md). Briefly: a repair's unit is the snapshot, not the
  calendar day, and a snapshot's readings scatter up to 22.7 hours behind and (for 11,855 August
  rows) years ahead, so a month partition would not contain a day's damage; finding the rows
  derived from a month's snapshots already takes 2.7 s thanks to the existing `id` minmax index;
  the ministry's future timestamps would mint about 140 junk partitions reaching to 2038; and
  repartitioning means rewriting 120 GiB on a machine whose I/O throttle exists because the
  first load made it unusable. Lightweight deletes do the job instead.
- **Every enrichment pass re-reads the whole retained landing table, four times over.**
  `siri_feed` is "everything in landing not yet enriched" with no date filter, and the six
  `enrich_*_src` views reference it four times between them. That cost nothing while landing held
  one hour; now that `DROP_LANDING=0` keeps whole months it holds 150,966,451 rows, and one pass
  reads **617,028,034 rows and 12.62 GiB** — 4.1 scans. At the 80 MiB/s ceiling in
  `ingest/local.xml` that is about 161 s of I/O before any join work, so a one-day pass measured
  about 24 minutes. `ingest/repair-range.sh` works around it by batching, which makes a range pay
  the scans once instead of once per day, but the underlying cost is still there and still grows
  with every month retained — including for `enrich_vehicle_location`, which refreshes every
  minute and needs more than a minute of I/O for a single pass. It corrupts nothing (a
  refreshable view cannot overrun itself; measured) but it is doing far more work per tick than
  it was designed for. The fix is to bound `siri_feed` by snapshot prefix, which would turn each
  scan from 151M rows into about 5.8M. Not done, and not measured.
- **The live feed is landing about two thirds of the archive.** Measured on 2026-11-07:
  2026/11/05 holds 959 snapshots and 2026/11/06 holds 952, against the roughly 1,428 S3 has. The
  cause is that every repair and backfill stops the live views for its duration, and the minutes
  that pass meanwhile are lost. `ingest/catchup.sh` now resumes from the oldest incomplete day
  within seven days instead of from the newest snapshot's day, which makes the hole reachable —
  but nothing has yet run long enough to confirm it closes.
- **PostgreSQL wins one query.** A selective `line_ref` + bounding-box filter is 0.017 s
  against 0.063–0.090 s, because B-tree indexes on `lon`/`lat` are the right tool. Closing it
  needs skip indexes. Not done.
- **Projections are 30% of the footprint, measured.** Four of them take the total from
  163.98 GiB to **233.02 GiB**: `gtfs_ride_stop.by_ride` 29.88 GiB, `siri_ride_stop.by_gtfs_stop`
  19.33 GiB, `siri_ride_stop.by_siri_ride` 18.95 GiB and `siri_ride.by_natural_key` 0.87 GiB.
  `siri_ride_stop` needs two because it is filtered by a different foreign key on each of two
  endpoints and sorted by neither. Quote 233 GiB, not 164. One of the four,
  `by_gtfs_stop`, is droppable: it serves only `/stop_arrivals/list`, which cannot return a row
  from production at all.
- **The `siri_ride_stop` projection is predicted, not measured.** The 0.015 s figure above is
  measured on `gtfs_ride_stop`; the second one is inferred from it.
- **`gtfs_ride_stop` is loaded but not refreshed.** The daily GTFS loader replaces the other
  GTFS tables; this one is a quarter of the database on its own and still dates from the dump.
- **61 rows in a measured minute still differ from production** in `scheduled_start_time`,
  cause unknown — see stage 3.
- **Nothing has run unattended for 24 hours.** The chain has been observed healthy repeatedly,
  but a full day of steady-state RSS and CPU is the number stage 5 should be sized on and it
  does not exist yet.
- **The public dump is 4.6 months old**, which bounds every differential test case that
  predates continuous ingest.

## On cost

The estimates in [docs/BENCHMARKS.md](docs/BENCHMARKS.md) are derived from published AWS and
Kamatera rates applied to specs declared in the public `hasadna-iac` Terraform, so they are
reproducible from public information and are included in full.

**What the project actually pays is not here.** That figure was reported to us privately and
belongs to the project's maintainers to publish or not. Where the analysis needs it — the
share of the bill that goes to ETL workers rather than to the database — the ratios are
computed from the public specs, which gives the same conclusion without the invoice.
