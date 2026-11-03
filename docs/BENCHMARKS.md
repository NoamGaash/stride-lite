# Stride DB Storage Benchmark — ClickHouse vs TimescaleDB vs PostgreSQL

Empirical comparison of storage volume for the Stride `siri_vehicle_location` data, run to
support the databus team's decision on replacing PostgreSQL with a compressed store.

**Status:** volume and latency results complete; the full 13.7-billion-row database is loaded
locally and 22 of 22 differential cases against production pass across 13 of 27 endpoints.
**Everything below marked "measured" was run in this environment; anything else is labelled.**

---

## 0. Bottom line

`siri_vehicle_location` holds **6,506,195,421 rows** — exact count from the 2026-06-14 dump,
47% of all rows in the database.

That covers **2022-01-16 → 2026-05-29, 1595 days (4.37 years)**. Sanity check: 6.506 billion
rows over 1595 days is an average of 4.08M rows/day, against 5.54M measured on a Tuesday —
a ratio of 0.74, which is what Shabbat and holidays should do to the average. The row count
and the period are consistent.

Every "final size" below is that full period.

| Solution                                    | bytes/row | Final size of `siri_vehicle_location` |
| ------------------------------------------- | --------- | ------------------------------------- |
| PostgreSQL as today — heap + PK + 5 indexes | 205.8     | **1.34 TB**                           |
| PostgreSQL heap only, no indexes            | 93.0      | 605 GB                                |
| TimescaleDB compressed, production schema   | 35.2      | **229 GB**                            |
| TimescaleDB compressed, denormalized schema | 29.6      | 193 GB                                |
| ClickHouse — org's current schema           | 24.41     | **159 GB**                            |
| ClickHouse — codecs + LowCardinality        | 22.73     | 148 GB                                |
| ClickHouse — ordered by `vehicle_ref`       | 11.12     | **72 GB**                             |

**1.34 TB → 159 GB with the schema already committed in the org's repo: 8.4×.** Paying the
latency cost of ordering by vehicle takes it to 72 GB, 18.6×.

Indexes are 55% of PostgreSQL's footprint today — 93 bytes of data against 107.6 bytes of
index per row.

**On latency: ClickHouse is fine, with one gap.** It wins the heavy fleet-wide scan by
5–8×, but loses the selective `line_ref` + bbox query to PostgreSQL (0.017 s vs 0.063–0.090 s)
because B-tree indexes on `lon`/`lat` are the right tool there. Closing that needs skip
indexes, which is real work not yet done. Compressed TimescaleDB is the weak option for
row-returning scans at 0.281 s, 40× ClickHouse.

### The whole database, loaded and measured — not extrapolated

Every table from the 2026-06-14 dump is now loaded into ClickHouse and verified row-for-row
against a streaming count of the dump. This replaces the extrapolation above for
`siri_vehicle_location` and closes the whole-database figure that was previously listed as
missing.

| Table                   | Rows               | Compressed     | bytes/row | Ratio    |
| ----------------------- | ------------------ | -------------- | --------- | -------- |
| `siri_vehicle_location` | 6,506,195,421      | **111.52 GiB** | 18.40     | 3.48     |
| `gtfs_ride_stop`        | 4,113,193,845      | 24.57 GiB      | 6.42      | 7.48     |
| `siri_ride_stop`        | 2,803,456,736      | 21.24 GiB      | 8.13      | 4.55     |
| `siri_ride`             | 110,227,936        | 2.58 GiB       | 25.12     | 4.76     |
| `gtfs_ride`             | 114,949,212        | 1.74 GiB       | 16.25     | 3.76     |
| `gtfs_stop`             | 35,376,512         | 920 MiB        | 27.28     | 3.41     |
| `gtfs_stop_mot_id`      | 35,376,527         | 407 MiB        | 12.06     | 1.16     |
| `gtfs_route`            | 6,969,141          | 142 MiB        | 21.42     | 9.67     |
| `siri_snapshot`         | 2,246,550          | 137 MiB        | 63.96     | 3.49     |
| 7 smaller tables        | 60,113             | < 1 MiB        | —         | —        |
| **Total**               | **13,728,053,041** | **163.22 GiB** | **12.76** | **4.24** |

**163 GiB holds the entire database**, against 692 GiB uncompressed. The one table the
benchmark focused on came in at **111.52 GiB rather than the 159 GB extrapolated** — the
extrapolation was 42% too high, because it scaled a single day of 2022 data and the per-row
cost falls as the table grows and the codecs get longer runs to work with. The direction of
that error is worth stating plainly: the benchmark understated how well this works.

The comparison against PostgreSQL's 1.34 TB for `siri_vehicle_location` alone therefore gets
better, not worse — but it stays an estimate on the PostgreSQL side, since
`pg_total_relation_size` still needs a production connection.

**What this does not cover:** the migration _plan_ still addresses `siri_vehicle_location`
only. `gtfs_ride_stop` and `siri_ride_stop` are loaded and measured here, but the ETLs that
would keep them current are not built.

---

## 1. Why

The Stride PostgreSQL database has grown to the point where its compressed dump alone is
154.6 GB. The team is evaluating ClickHouse, TimescaleDB, or another compressed engine.

Two questions:

1. How much will the data weigh in each option?
2. Will the queries the project actually runs get materially slower?

Note that a ClickHouse migration is already in progress in the org:
[hasadna/open-bus-stride-clickhouse](https://github.com/hasadna/open-bus-stride-clickhouse)
(created 2026-09-16) has the schema, dbt models and backfill macros, and its `PLAN.md`
states the goal as "Move data off the PostgreSQL database and into ClickHouse". This
benchmark validates a decision already in motion rather than opening a new one.

## 2. Environment

|             |                                                                                          |
| ----------- | ---------------------------------------------------------------------------------------- |
| Hardware    | 24 cores, 60 GB RAM, overlay filesystem                                                  |
| ClickHouse  | 26.10.1.1600 (Apache-2.0)                                                                |
| PostgreSQL  | 17.11 (Debian) — **production is 14.2**, see caveat in §8                                |
| TimescaleDB | 2.31.0, TSL build from Timescale's own apt repo                                          |
| Source dump | `pg_dump -n public --no-privileges \| zstd -19`, 154,630,881,726 bytes, taken 2026-06-14 |

## 3. Dataset

All engine comparisons use **the same 5,538,687 rows**: one full day (2022-06-14, a Tuesday)
of SIRI vehicle locations, exported once to TSV and loaded identically into every engine.

Using one fixed dataset across engines is what makes the comparison valid. Where a result
uses different data, it is called out.

A second scale point uses 10,875,956 rows (two days).

## 4. Result: volume by engine

Same 5,538,687 rows in every row of this table.

| Solution                                  | bytes/row | size for this day | **full history** | vs best  |
| ----------------------------------------- | --------- | ----------------- | ---------------- | -------- |
| PostgreSQL + 5 indexes                    | 215.4     | 1138 MB           | **1.40 TB**      | 19.4×    |
| TimescaleDB hypertable, **uncompressed**  | 161.5     | 853 MB            | **1.05 TB**      | 14.5×    |
| PostgreSQL, no indexes                    | 148.9     | 786 MB            | **969 GB**       | 13.4×    |
| TimescaleDB hypertable, **compressed**    | 29.70     | 157 MB            | **193 GB**       | 2.7×     |
| ClickHouse — org's current schema         | 24.41     | 129 MB            | **159 GB**       | 2.2×     |
| ClickHouse — codecs + LowCardinality      | 22.73     | 120 MB            | **148 GB**       | 2.0×     |
| **ClickHouse — ordered by `vehicle_ref`** | **11.12** | **59 MB**         | **72 GB**        | **1.0×** |

The full-history column is bytes/row × 6,506,195,421 rows — the exact
`siri_vehicle_location` count from the dump. It is an extrapolation, not a measurement; see
the era caveat in §8.

TimescaleDB compression used `compress_segmentby='vehicle_ref'`,
`compress_orderby='recorded_at_time'` — deliberately mirroring the ClickHouse variant that
won, so the two are compared on the same physical layout idea.

## 4b. Result: query latency

Median of 5 warm runs, in seconds, same 5,538,687 rows in every engine. Lower is better;
**bold** marks the winner per query.

| Query                      | ClickHouse A | ClickHouse C | ClickHouse D | PG + indexes | Timescale compressed |
| -------------------------- | ------------ | ------------ | ------------ | ------------ | -------------------- |
| Q1 — fleet 1h, aggregate   | 0.011        | **0.008**    | 0.014        | 0.066        | 0.094                |
| Q1b — fleet 1h, 10k rows   | **0.005**    | 0.006        | 0.027        | 0.007        | 0.281                |
| Q2 — line + bbox + 8h      | 0.090        | 0.063        | 0.031        | **0.017**    | 0.066                |
| Q4 — line + vehicle lookup | 0.012        | 0.012        | 0.005        | 0.005        | **0.004**            |

Four things worth carrying into the decision:

- **ClickHouse dominates the wide scan.** Q1 is 5–8× faster than PostgreSQL and 7–12×
  faster than compressed TimescaleDB. Q1 is also the query shape the heaviest frontend
  pages issue.
- **Variant D's storage win costs latency on exactly the query that matters most.** 2.2×
  smaller, but Q1b goes 0.006 → 0.027 s, 4.5× slower. The trade-off predicted in §5 is real
  and measured.
- **Compressed TimescaleDB is the worst option for row-returning scans.** 0.281 s on Q1b,
  40× ClickHouse C, because every returned row has to be decompressed. Its compression
  buys 5.4× on disk and costs that.
- **PostgreSQL with its indexes wins the selective query.** Q2 at 0.017 s beats every
  ClickHouse variant, because B-tree indexes on `lon`, `lat` and `line_ref` are simply the
  right tool for a narrow filter. A production ClickHouse would need skip indexes to close
  this, and that is work the current `open-bus-stride-clickhouse` schema has only partly
  done (it has one skip index, on `scheduled_start_time`).

**These latencies are at 1/2000-ish of production scale** (one day vs the full history), so
they do not extrapolate directly. Expect the ordering on Q1 to widen further in ClickHouse's
favour as data grows, since the scan cost tracks bytes read and ClickHouse reads 6–19× less.
Point lookups like Q4 should stay flat everywhere.

## 5. Result: the biggest lever is `ORDER BY`, not codecs

ClickHouse schema variants, all on the same day:

| Variant | Definition                                                                 | bytes/row | full history |
| ------- | -------------------------------------------------------------------------- | --------- | ------------ |
| A       | org's current schema — every column `String`, `ORDER BY recorded_at_time`  | 24.41     | 159 GB       |
| B       | typed with `Nullable(Float64)` / `Nullable(Int32)`                         | 28.16     | 183 GB       |
| C       | `Float32`, `UInt16`, `LowCardinality`, ZSTD/Gorilla/T64/DoubleDelta codecs | 22.73     | 148 GB       |
| D       | C, but `ORDER BY (vehicle_ref, recorded_at_time)`                          | **11.12** | **72 GB**    |

Per-column bytes/row shows the mechanism:

| Column               | C (`ORDER BY recorded_at_time`) | D (`ORDER BY vehicle_ref, …`) |
| -------------------- | ------------------------------- | ----------------------------- |
| `lat`                | 3.43                            | 2.14                          |
| `lon`                | 3.13                            | 1.99                          |
| `distance_from_stop` | —                               | 1.67                          |
| `recorded_at_time`   | —                               | 1.13                          |

Ordered by time, consecutive rows are unrelated vehicles scattered across the country, so
delta-style codecs have nothing to exploit. Ordered by vehicle, consecutive rows are the
same bus a minute later and every column becomes highly predictable.

**This 2.2× is not free.** `ORDER BY (vehicle_ref, …)` is good for per-vehicle queries and
bad for whole-fleet time-window scans — which is the heaviest query the frontend issues
(see §7, Q1). The org's current `ORDER BY recorded_at_time` plus its `scheduled_start_time`
skip index is tuned for exactly that scan. Treat the 2.2× as a trade-off to measure, not a
win to bank.

## 6. Result: bytes/row improves with scale, then plateaus

Measured on ClickHouse variant B, identical data, increasing row counts:

| Rows                | bytes/row | compression ratio |
| ------------------- | --------- | ----------------- |
| 1,000,000           | 52.54     | 3.06              |
| 5,538,687 (1 day)   | 28.16     | 5.72              |
| 10,875,956 (2 days) | 28.01     | 5.74              |

Halving from 1M to 5.5M, then flat. So a full day is already in the flat region and
extrapolating from one day is defensible.

PostgreSQL, by contrast, is completely flat across scale — 148.8 → 148.9 bytes/row from one
day to two. No compression, fixed per-row overhead. The scale effect applies only to
columnar/compressed stores.

## 7. Production row counts (from the dump)

A single streaming pass over the dump counts rows per table without restoring anything.
These are exact counts from the 2026-06-14 dump:

| Table                          | Rows              | Text bytes   |
| ------------------------------ | ----------------- | ------------ |
| `gtfs_ride_stop`               | 4,113,193,845     | 335 GB       |
| `siri_ride_stop`               | 2,803,456,736     | 114 GB       |
| `gtfs_ride`                    | 114,949,212       | 10.9 GB      |
| `siri_ride`                    | 110,227,936       | 14.8 GB      |
| `gtfs_stop_mot_id`             | 35,376,527        | 838 MB       |
| `gtfs_stop`                    | 35,376,512        | 3.2 GB       |
| `gtfs_route`                   | 6,969,141         | 1.1 GB       |
| `siri_snapshot`                | 2,246,550         | 554 MB       |
| `clustertoline`                | 2,641             | 255 KB       |
| `gtfs_data` / `gtfs_data_task` | 1,595 each        | 380 KB       |
| `siri_route`                   | 17,777            | 241 KB       |
| `siri_stop`                    | 36,496            | 433 KB       |
| **`siri_vehicle_location`**    | **6,506,195,421** | **544.8 GB** |

Total across all tables: **13.73 billion rows, 1.03 TB of COPY text.** The pass took 22
minutes.

`gtfs_ride_stop` at 4.1 **billion** rows is a second monster table that was not on anyone's
radar in the original plan. Any migration plan that covers only `siri_vehicle_location` is
addressing less than the whole problem.

### Queries that must not regress

These are the calls the frontend actually issues, to be used for the latency half of this
benchmark:

| #   | Source                                     | Shape                                                                                                                           | Page                          |
| --- | ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------- | ----------------------------- |
| Q1  | `src/hooks/useVehicleLocations.ts:123-125` | `siriVehicleLocationsListGet` with only `recordedAtTimeFrom/To` — whole-fleet time-window scan, the heaviest                    | timeBasedMap, velocityHeatmap |
| Q2  | `src/api/siriService.ts:32-41`             | same endpoint + `siriRoutesLineRef` + 8h window + lat/lon bbox + `orderBy distance_from_siri_ride_stop_meters desc`, limit 1024 | stationStops                  |
| Q3  | `src/api/groupByService.ts:41-48`          | `byGtfsRidesAggGroupByGet` with date range, `groupBy`, `excludeHoursFrom/To`                                                    | dashboard                     |
| Q4  | `src/api/siriService.ts:19-24`             | `siriRidesListGet` with route/line/vehicle refs, limit 1                                                                        | singleLineMap                 |

## 8. Caveats that limit what these numbers mean

- **The PostgreSQL rows in §4 are not the production schema.** To compare like with like
  against ClickHouse, all engines got the same denormalized 15-column table. Production
  `siri_vehicle_location` is normalized — 10 narrower columns with FKs to `siri_snapshot`
  and `siri_ride_stop`, no inline text refs — so it is smaller per row. **Do not extrapolate
  148.9 or 215.4 to production.** The real production figure has to come from
  `pg_total_relation_size` on the live DB.
- **Local PostgreSQL is 17.11; production is 14.2.** Acceptable for relative engine
  comparison, but the absolute PostgreSQL numbers should be sanity-checked against
  production.
- **bytes/row is strongly data-dependent across eras.** The same ClickHouse schema A gave
  24.41 bytes/row on 2022 data and 46.2 on 2026 data — nearly 2×. A single-era measurement
  cannot be extrapolated across the full history; the final estimate needs a figure per era.
- **Volume results are hardware-independent and transfer to production. Latency results
  will not be** — they were taken on 24 cores / 60 GB and are only valid as ratios between
  engines on the same machine.
- Variant D and the TimescaleDB compression setting both drop NULL/zero distinctions where
  `NOT NULL` defaults were used; fine for sizing, not for semantics.
- **The production-schema measurements use synthetic `id`, `siri_snapshot_id` and
  `siri_ride_stop_id` values**, because the real normalized rows were not extracted. For
  PostgreSQL this does not matter — those columns are fixed-width and uncompressed, so 205.8
  bytes/row stands. For _compressed_ engines it matters a lot and in the pessimistic
  direction: random integers do not compress, where the real columns are sequential and
  time-correlated and would compress well. So TimescaleDB's 35.2 bytes/row on the production
  schema is an upper bound, and the true figure is lower.

## 9. Things this benchmark got wrong along the way

Recorded because the wrong versions were stated out loud before being corrected.

- **"Typing the columns cuts ~39%."** Wrong. Measured on identical data, the org's
  all-`String` schema (24.41) beats a naively typed `Nullable` schema (28.16). The original
  39% came from comparing two different days with different partitioning. `Nullable` adds a
  null mask per column, `Float64` compresses poorly, and digit strings compress very well.
  Typing only wins when combined with `Float32`, `NOT NULL` and codecs — variant C, and even
  then only 7%.
- **"~700 GiB for the full history."** Built on a single 2026 day, i.e. the pessimistic end
  of a 2× data-dependent spread, and on schema A rather than a tuned one. The measured
  figure for schema A is 159 GB.
- **"The dump is ~2.2 TB of SQL text."** Wrong by 2×. Extrapolated from the compression
  ratio of the first 8 GB, which covers `gtfs_ride` and `gtfs_ride_stop` — highly repetitive
  integer rows that compress far better than the float-heavy `siri_vehicle_location` filling
  the rest of the file. Ratio over the first 8 GB is 14.3×; over the whole dump it is 6.6×,
  for 1.03 TB. Never extrapolate a compression ratio from the head of a heterogeneous file.
- **A TimescaleDB compression setting that made the table 2.5× bigger.** Choosing
  `compress_segmentby='siri_snapshot_id'` produced 105.8 → 272.7 bytes/row, because that
  column has millions of distinct values and segmentby builds one compressed group per
  value — groups of ~2.5 rows, all overhead. TimescaleDB warned about it explicitly
  (`poor compression ratio detected ... 0.39`). Dropping segmentby gave 35.2 bytes/row.
  Worth knowing before anyone tunes this in production: a bad `segmentby` is worse than none.

## 10. Operational findings, incidental to the benchmark

- **TimescaleDB compression is not in Debian's package.** `postgresql-17-timescaledb` sets
  `Files-Excluded: tsl` — Debian strips the TSL-licensed directory, so
  `ALTER TABLE … SET (timescaledb.compress …)` fails with
  `functionality not supported under the current "apache" license`. Compression requires the
  build from Timescale's own apt repo.
  The Timescale License permits free production use with no fee and no user limit, but
  places conditions on offering the software as a service. Whether a read-only public API,
  or handing out direct SQL access (the ClickHouse repo already carries a
  `limited_read_role.sql` migration), falls inside those conditions is a question for a
  lawyer and not for this document. ClickHouse is Apache-2.0 and raises no equivalent
  question.
- **`distance_from_stop` contains garbage in the raw MOT feed** — values from −977,940,286
  to 1,229,615,254. Anything computing on that column needs to clamp or filter it.
- **`gtfs_rides_agg` and `gtfs_rides_agg_by_hour` are materialized views**, and `pg_dump`
  stores their definitions, not their contents. Restoring requires an expensive `REFRESH`,
  and Q3 above depends on them.
- **A full restore of this dump is impractical on a machine like this one.** The dump holds
  1.03 TB of COPY text (overall compression ratio 6.6×), replayed single-threaded through
  `psql` because it is a plain dump rather than `-Fc`, and the restored database with its
  indexes would be several TB. Filtered streaming extraction is the practical route; a
  single streaming pass over the whole dump takes 22 minutes.
- **The production backup is stale.** `s3://openbus-stride-public/stride_db.sql.zst` was
  last modified 2026-06-14 despite a daily 01:37 cron and a StatusCake heartbeat that should
  alert after two days. The `stride-etl-db-copy-backup-to-s3` DAG last ran in 2022; it reads
  a file from the k8s deployment's NFS, and that deployment has `db.enabled: false`.
  Reported upstream separately. For this work it is simply the constraint that bounds every
  differential test case to data ending 2026-05-29.

## 11. Reproducing

The raw SIRI snapshots are public and need no credentials, and the org's ingest macro reads
them directly — no database dump required:

```
just data-ingest-backfill 2026 08 01 02    # in hasadna/open-bus-stride-clickhouse
```

Measuring volume in ClickHouse:

```sql
select sum(rows), formatReadableSize(sum(data_compressed_bytes)),
       round(sum(data_compressed_bytes)/sum(rows),2) as bytes_per_row
from system.parts where table='...' and active;
```

Per-column breakdown, which is what revealed the `ORDER BY` finding:

```sql
select column, round(sum(column_data_compressed_bytes)/<rows>,2) as bytes_per_row
from system.parts_columns where table='...' and active
group by column order by sum(column_data_compressed_bytes) desc;
```

Always `optimize table … final` in ClickHouse and `vacuum analyze` in PostgreSQL before
measuring, or unsettled merges and bloat inflate the numbers.

## 11b. Storage cost

Monthly storage cost for `siri_vehicle_location` alone, at the sizes from §0.

| Solution                              | Size    | Kamatera ($0.05/GB-mo) | AWS EBS gp3 ($0.08/GB-mo) |
| ------------------------------------- | ------- | ---------------------- | ------------------------- |
| PostgreSQL as today                   | 1.34 TB | **$67**                | **$107**                  |
| TimescaleDB compressed                | 229 GB  | $11                    | $18                       |
| ClickHouse — org's current schema     | 159 GB  | $8                     | $13                       |
| ClickHouse — ordered by `vehicle_ref` | 72 GB   | $4                     | $6                        |

Managed options, for reference: ClickHouse Cloud bills compressed storage at roughly
$25.30/TB-mo (~$4 for 159 GB); Tiger Cloud (TimescaleDB) high-performance storage at roughly
$0.15/GB-mo (~$34 for 229 GB), with tiered cold object storage around $0.02/GB-mo. Kamatera
is listed because that is where Hasadna already runs (see `kamatera_server.rke2` in
`hasadna-iac`).

**Storage cost is not the argument for migrating.** The whole saving from 1.34 TB down to
159 GB is about $60/month on the current provider. What costs real money is the RAM needed
to serve queries over 1.34 TB — a Kamatera box with 8 GB is $40/month, and one with 32–64 GB
is several hundred.

Two things that _do_ make a financial case:

- **Growth.** 4.08M rows/day is 1.49 billion rows/year: **+307 GB/year in PostgreSQL versus
  +36 GB/year in ClickHouse.** PostgreSQL doubles roughly every 4.4 years, ClickHouse's
  growth is a rounding error against the same provisioning.
- **This is one table.** With `gtfs_ride_stop` and `siri_ride_stop` the whole database is
  plausibly 2.5–3 TB, i.e. $125–150/month on Kamatera — but those two tables were not
  measured in any engine, so that figure is inference from row counts, not measurement.

Price caveat: the Kamatera and EBS rates are consistent across sources; the ClickHouse Cloud
and Tiger Cloud rates come from third-party trackers that disagree with each other and could
not be confirmed on the vendors' live pricing pages. Verify before relying on them.

## 11c. RAM

Measured peak memory per query in ClickHouse:

| Query                               | Peak memory |
| ----------------------------------- | ----------- |
| Q1 — 1-hour aggregate               | **72 KB**   |
| Q1b — 10,000 rows returned          | **864 KB**  |
| Full-day aggregate with `uniqExact` | **25 MB**   |
| Full scan with `group by`           | **227 KB**  |

ClickHouse needs essentially no RAM for this workload; 8–16 GB is ample.

PostgreSQL today runs on 6 cores and 32 GB with `shared_buffers = 4GB`,
`effective_cache_size = 24GB` **and 32 GB of manually added swap** (see the provisioning
notes in `hasadna-iac/modules/openbus/stride_db_server.tf`). Swap on a database server is a
memory-pressure signal. Against 701 GB of indexes, 32 GB of RAM caches 4.5%.

It works anyway because the queries are index-bounded, not size-bounded: the 1-hour window
query touched 3,744 buffers, 30 MB. That cost does not grow as the database grows.

Index sizes on the production schema, measured at 5,538,687 rows and scaled to 6.51 billion:

| Index               | Measured   | At full scale |
| ------------------- | ---------- | ------------- |
| `lon`               | 119 MB     | 140 GB        |
| `lat`               | 119 MB     | 140 GB        |
| PK on `id`          | 119 MB     | 140 GB        |
| `siri_ride_stop_id` | 119 MB     | 140 GB        |
| `siri_snapshot_id`  | 83 MB      | 98 GB         |
| `recorded_at_time`  | 38 MB      | 45 GB         |
| **Total**           | **597 MB** | **701 GB**    |

The time index is a third the size of the others because the heap is already physically
ordered by time.

## 11d. Traffic

Measured API payload: **150 bytes/row as JSON, 17 bytes/row gzipped.** Q1b's 10,000 rows is
1.5 MB raw, 0.17 MB gzipped.

Kamatera includes roughly 5 TB per server with overage at $0.01/GB, so across eight servers
this traffic is almost certainly inside the included allowance. More importantly the database
sits on the cluster's internal LAN, so API↔DB traffic is free.

**That is the argument against DBaaS:** moving the database off-premises converts free LAN
traffic into billed WAN traffic in both directions.

Unverified caveat: every server is declared `cpu_type = "B"` (burstable), and one third-party
source claims burstable instances get no free bandwidth. If true it changes this calculation.

## 11e. What the Kamatera bill actually pays for

Specs are declared in the public `hasadna-iac` Terraform, and the rates below are Kamatera's
published ones. The actual invoice total was reported to us privately and is not ours to
publish, so every figure here is derived from public information:

| Server          | Cores   | RAM        | Disk                     |
| --------------- | ------- | ---------- | ------------------------ |
| stride-db       | 6       | 32 GB      | 3000 GB                  |
| controlplane1   | 8       | 16 GB      | 100 GB                   |
| critical1       | 8       | 16 GB      | 1100 GB                  |
| critical2       | 8       | 16 GB      | 1100 GB                  |
| worker1–worker4 | 24 each | 64 GB each | 750 / 950 / 250 / 250 GB |
| **Total**       | **126** | **336 GB** | **7.5 TB**               |

At Kamatera's published rates that is roughly **$1,950/month (₪7,200)**. Expect the real
invoice to run higher than that: these per-unit rates come from small published plans, and
larger configurations cost more per unit. The ratios below depend only on the specs, so they
hold either way.

The split is the point:

|                                       | Share of the bill |
| ------------------------------------- | ----------------- |
| The four workers (Airflow + the ETLs) | **67%**           |
| controlplane + critical nodes         | 19%               |
| **The database server**               | **14%**           |

**The database server is not most of the bill — the ETL workers are.** A migration that only
changes storage caps its saving at the 3 TB disk: dropping to 1 TB saves about $100/month,
4% of the bill.

The real lever is in the org's own `PLAN.md`: "related ETL tasks are handled by clickhouse
materialized views refreshed every 10 minutes". If the migration retires Airflow DAGs, it
attacks the 67%, not the 14%. The Airflow scheduler alone requests 20–25 GB of RAM and 2
cores in `values-hasadna.yaml`.

**Next thing to measure:** which DAGs disappear under the ClickHouse design, and what RAM and
CPU they consume today. That, not storage, decides whether this migration pays for itself.

Caveat on the 67%: that is a cost allocation by server spec, not a measurement of what runs
on those workers. The RKE2 cluster is shared with other Hasadna projects (meirim, migdar,
odata), so "67% is workers" is not the same as "67% is Open Bus ETL".

## 11f. Why the ETL is expensive — measured

The hourly DAGs are `UPDATE` statements against the two largest tables in the database.
From `STRIDE_ETL_PROCESSES.md`:

- `stride-etl-siri-update-ride-stops-vehicle-locations` updates
  `siri_vehicle_location.distance_from_siri_ride_stop_meters` — 6.51 billion rows
- `stride-etl-siri-update-ride-stops-gtfs` updates `siri_ride_stop.gtfs_stop_id` — 2.80 billion rows
- `stride-etl-siri-add-ride-durations` "runs every hour and repopulates all ride durations"

Measured cost of updating **one non-indexed column** across 5,538,687 rows of the production
schema:

|               |                                       |
| ------------- | ------------------------------------- |
| Time          | **81.3 s**                            |
| WAL generated | **3.52 GB** (44.7M records)           |
| Table before  | 1087 MB (491 heap + 596 indexes)      |
| Table after   | **2229 MB** (982 heap + 1247 indexes) |
| Dead tuples   | 5,538,687                             |

The indexes grew from 596 MB to 1247 MB **even though the updated column is not indexed**:
every `UPDATE` writes a new row version and all six indexes need a new entry pointing at it.
`VACUUM` then took 2 s and reclaimed **nothing** — the table stays at 2229 MB. Only
`VACUUM FULL` returns the space, and it needs free disk equal to the table.

Scaled to 6.51 billion rows, one full pass is **26.5 hours and 4.1 TB of WAL**. That is a
backfill figure, not an hourly one: these DAGs run incrementally (the durations task is gated
on `updated_duration_minutes IS NULL`).

Two limits on this measurement. It was fully warm — `shared hit=122359242 read=75922`, so
essentially nothing came from disk, which is trivially true for a 5.5M-row table with 596 MB
of indexes and false for production's 701 GB against 32 GB of RAM. And it updates every row,
where the real DAGs update a scattered recent subset. So the per-row cost here is a floor.

The same work as a read-time computation in ClickHouse, on the same 5.54M rows:

| Computation                                             | Time        | Bytes written |
| ------------------------------------------------------- | ----------- | ------------- |
| `geoDistance` over every row                            | **0.026 s** | 0             |
| Per-ride min/max/duration aggregation for the whole day | **0.087 s** | 0             |

Peak memory for the geo computation: 163 KB.

**The steady-state ETL write load is not actually expensive, and an earlier draft of this
document was wrong to imply it was.** The hourly DAGs are incremental, so they touch roughly
170k rows an hour (4.08M/day ÷ 24), not millions. At the measured per-row cost that is about
2.5 seconds and 108 MB of WAL per hour.

Measured insert cost for one hour of production volume, 170,000 rows:

|                               | Time       | WAL       | WAL records   |
| ----------------------------- | ---------- | --------- | ------------- |
| No indexes                    | 97 ms      | 20 MB     | 170,000       |
| With the 6 production indexes | **977 ms** | **97 MB** | **1,197,911** |

Indexes cost 10× the time and 4.8× the WAL, and produce 7 WAL records per row instead of 1 —
one heap plus six index entries. The mechanism is real. The absolute number is not: one
second per hour, 24 seconds and 2.3 GB of WAL per day.

So the expensive parts are elsewhere:

- **Airflow's own footprint.** `values-hasadna.yaml` requests `cpu: 2000m` and
  `memory: 20000Mi` for the scheduler, with a 25 GB limit — 20–25 GB of RAM and two cores to
  orchestrate tasks that take seconds. That is orchestration cost, not data cost, and it is
  why replacing DAGs with materialized views refreshed every 10 minutes is cheaper: it
  deletes the orchestrator, not the work.
- **Storage.** 1.34 TB for one table, 701 GB of it indexes. Measured, and real.
- **Backfills, where the 10× does bite.** Reloading the full history is 6.51 billion rows:
  at the measured warm rate that is **10.4 hours and 3.7 TB of WAL**, and production's 701 GB
  of indexes against 32 GB of RAM makes it materially worse.

The architectural point stands regardless: the pipeline exists to pre-materialize values that
are derivable — distance from stop, ride duration, GTFS stop matching. PostgreSQL forces
materialization because computing them per query over 6.5 billion rows in a row store is not
viable; ClickHouse does it in 26 ms.

It is architecture, not accident: `siri_ride_stop` (2.80 billion) and `gtfs_ride_stop` (4.11
billion) exist _only_ as ETL output. **Half the database — 6.9 of 13.7 billion rows — is
cached ETL results.** That is where the twelve DAGs, the Airflow scheduler's 20–25 GB request,
the 3 TB disk and the 32 GB of swap all come from.

Operational risk worth naming: `VACUUM FULL` on a 1.34 TB table needs 1.34 TB of free disk
and hours of downtime. With 3 TB provisioned and most of it in use, that option may not be
available at all.

On DBaaS: Hasadna already owns 336 GB of RAM and 126 cores, and ClickHouse needs 8–16 GB, so
it fits existing headroom at near-zero marginal cost. A managed service adds a new bill, adds
egress that is currently free, and for TimescaleDB adds the licensing question from §10. It
buys maintenance time, not money.

## 11g. Rebuild architecture — what the backend looks like without Airflow

An experiment in rebuilding the whole backend ClickHouse-native, to measure resources and
price it on AWS against a $150/month target. Two load-bearing claims, both verified here:

**ClickHouse ingests from S3 with no application code.**

```sql
select count() from s3(
  'https://openbus-stride-public.s3.eu-west-1.amazonaws.com/stride-siri-requester/2026/05/20/08/{00..59}.br',
  NOSIGN, 'JSONEachRow', 'Siri Tuple(...)')
array join Siri.ServiceDelivery.StopMonitoringDelivery as d
array join d.MonitoredStopVisit as v
```

426,476 rows from one hour of snapshots in **2.087 s**. `NOSIGN` is required for the public
bucket; without it ClickHouse refuses to use server credentials for user queries.

**ClickHouse schedules its own refreshes.** A `REFRESH EVERY 1 MINUTE` materialized view
reports in `system.view_refreshes`:

```
view: test_refresh   status: Scheduled
last_refresh_time: 2026-11-02 18:14:00   next_refresh_time: 2026-11-02 18:15:00
```

That table tracks `status`, `exception`, `retry`, `progress`, `read_rows` and `written_rows` —
the observability Airflow was providing, inside the database.

### The resulting stack

| Layer           | Technology                                      | New application code  |
| --------------- | ----------------------------------------------- | --------------------- |
| SIRI collection | the existing Python `siri-requester`, unchanged | none                  |
| SIRI ingest     | ClickHouse `s3()` + refreshable MV              | **none**              |
| GTFS ingest     | shell: curl, unzip, `clickhouse-client`         | ~15 lines             |
| Enrichment      | ClickHouse materialized views                   | **none**              |
| Scheduling      | ClickHouse `REFRESH EVERY`                      | **none**              |
| Monitoring      | `system.view_refreshes`                         | **none**              |
| API             | TypeScript                                      | the only real service |
| Infrastructure  | Terraform                                       | —                     |

TypeScript earns its place at the API: the REST contract must stay compatible, the generated
client `@hasadna/open-bus-api-client` is already TypeScript, and the frontend is TypeScript,
so types are shared. Terraform earns its place because `hasadna-iac` is already Terraform.
Python stays only where it already works — the collector, which is the data source and not
worth the risk of a rewrite.

### Why 2.9 billion rows disappear

The org's migrations define the entity identities as **`ALIAS` columns**, not tables:

```sql
add column siri_route_id     String   alias concat(line_ref, ';', operator_ref),
add column siri_ride_id      String   alias concat(siri_route_id, ';', journey_ref),
add column siri_ride_stop_id String   alias concat(siri_ride_id, ';', siri_stop_id, ';', stop_order)
```

In PostgreSQL `siri_ride` (110M rows), `siri_ride_stop` (2.80B), `siri_route` and `siri_stop`
are tables the ETL populates. Here they are computed expressions costing zero storage.

### `gtfs_ride_stop` — the hypothesis was wrong, the conclusion holds anyway

An earlier draft claimed the 4.11 billion `gtfs_ride_stop` rows would shrink by orders of
magnitude because GTFS defines `stop_times` once per feed version rather than per date. That
reasoning is wrong, and measuring one real feed shows why.

One `israel-public-transportation.zip` (2026-05-20, 170 MB) contains:

| File         | Rows           |
| ------------ | -------------- |
| `stop_times` | **18,278,534** |
| `trips`      | 496,063        |
| `calendar`   | 55,077         |
| `stops`      | 34,974         |
| `routes`     | 7,879          |

PostgreSQL's 4.11 billion `gtfs_ride_stop` rows over 114.9 million `gtfs_ride` rows is 35.8
stops per ride, matching `stop_times / trips` = 36.8 — so it is indeed trips expanded by
service date. But the feed is re-downloaded daily, so _storing every feed version_ would be
1595 × 18.28M = **29 billion rows**, seven times worse. Expanding to service dates is what
makes PostgreSQL's model the compact one.

Measured in ClickHouse, 18,278,534 rows loaded in 3 seconds:

|                   |               |
| ----------------- | ------------- |
| Size              | **50.81 MiB** |
| bytes/row         | **2.91**      |
| Compression ratio | **23.4×**     |

And near-identical feed versions compress into each other. Five copies under different
`feed_date` values, sorted `(trip_id, stop_sequence, feed_date)`:

|            | Rows   | Size       | bytes/row |
| ---------- | ------ | ---------- | --------- |
| 1 version  | 18.28M | 50.81 MiB  | 2.915     |
| 5 versions | 91.39M | 117.66 MiB | **1.35**  |

Five times the rows for 2.3 times the bytes — each extra version costs 16.7 MiB, 67% less
than the first. These are identical copies, so that is a best case and a floor, not a ceiling.

**The resulting design decision inverts the earlier one:**

| Approach                                                   | Size                                    |
| ---------------------------------------------------------- | --------------------------------------- |
| Materialize the service-date expansion, as PostgreSQL does | **~12 GB** (4.11B × 2.91)               |
| Store every daily feed version                             | **≥26 GB** (1595 × 16.7 MiB, best case) |

So PostgreSQL's data model is right and it simply pays about 50× for it — the dump's text for
that table is 335 GB, and a heap plus indexes would plausibly be 600–820 GB. Materializing
the same expansion is both cheaper and simpler than query-time calendar expansion, which also
satisfies the simplicity criterion.

**Whole-database projection**: ~173 GB for `siri_vehicle_location` at today's row count, ~12 GB
for the GTFS expansion, and the rest negligible — call it **~185 GB** against a PostgreSQL
database that is plausibly 2.5–3 TB.

### The S3 + Parquet alternative — measured

A proposal from the team: skip the database. The raw data already lives in S3, so store
everything as Parquet there and query it with Athena or DuckDB. Storage and compute decouple,
and Parquet gives columnar compression for free.

Measured on the same 5,538,687 rows, same schema:

| Format                                            | bytes/row |
| ------------------------------------------------- | --------- |
| Parquet + zstd, time-ordered                      | **21.38** |
| ClickHouse MergeTree, time-ordered (variant C)    | 22.73     |
| Parquet + snappy, time-ordered                    | 23.71     |
| ClickHouse MergeTree, vehicle-ordered (variant D) | **11.12** |
| Parquet + zstd, vehicle-ordered                   | 14.03     |

Compression is a tie — Parquet wins by 6% on the time-ordered layout, ClickHouse wins by 26%
on the vehicle-ordered one where its `Delta`/`T64`/`Gorilla` codecs have something to work
with. **Parquet is not a compromise on storage.**

Query latency, DuckDB v2.0.0 over local Parquet, median of 5:

| Query                      | DuckDB + Parquet | ClickHouse C | ClickHouse D |
| -------------------------- | ---------------- | ------------ | ------------ |
| Q1 — fleet 1h aggregate    | **0.007 s**      | 0.008        | 0.014        |
| Q2 — line + bbox + 8h      | **0.032 s**      | 0.063        | 0.031        |
| Q4 — line + vehicle lookup | **0.006 s**      | 0.012        | 0.005        |

**DuckDB over local Parquet matches or beats ClickHouse** — 2× faster on Q2 and on Q4.

And the storage cost nearly vanishes. Full history as Parquet:

|                              | Size    | S3 Standard/month |
| ---------------------------- | ------- | ----------------- |
| Parquet, time-ordered        | 151 GB  | **$3.48**         |
| Parquet, vehicle-ordered     | 99 GB   | **$2.28**         |
| ClickHouse on EBS gp3        | 173 GB  | $13.84            |
| PostgreSQL today on Kamatera | 1.46 TB | $73               |

#### Where it breaks: Athena's billing model, not its technology

Athena is $5 per TB scanned **with a 10 MB minimum per query**, so every query — however
small — costs $0.00005. That makes the bill scale with traffic, the opposite of a fixed
instance:

|                 | Cost                                 |
| --------------- | ------------------------------------ |
| Fixed m7g.large | $66/month, unlimited queries         |
| Athena          | $0.00005/query                       |
| **Crossover**   | **1.32M queries/month = 44,000/day** |

Below that Athena is cheaper with zero operations. Above it a fixed instance wins and the gap
widens. Separately, and **not measured here**, Athena carries a query-planning latency floor
of roughly a second even on tiny scans, which rules it out as the direct backend for an
interactive map and keeps it well suited to ad-hoc analysis.

#### The S3 latency question is open, and this machine cannot settle it

S3 time-to-first-byte measured from this machine: **~347 ms**, throughput 7.2 MB/s. But this
machine is not in eu-west-1, so those numbers include crossing the internet. In-region TTFB
is typically 10–30 ms. Settling this needs an instance in the bucket's region, which is
stage 5 work.

#### Synthesis

The proposal is right about storage and wrong about serving, and those are separable:

- **S3 + Parquet as the durable layer.** Near-free, no server, and where the data already is.
- **A small stateless node with local Parquet or a local cache for serving** — which is the
  7 ms measured above.

This fits the data: an append-only time series where most queries hit recent data. Keep
recent partitions local, history in S3, and let the engine span both — ClickHouse has this as
tiered storage, DuckDB can union local and remote Parquet. That is not a compromise between
the two approaches; it takes the cheap half of each.

### AWS cost estimate against the $150/month target

All in eu-west-1, where the raw archive already lives, so S3 reads are same-region and free.

| Component                               | Monthly                                             |
| --------------------------------------- | --------------------------------------------------- |
| m7g.large (2 vCPU, 8 GB) for ClickHouse | $66                                                 |
| EBS gp3, 300 GB                         | $24                                                 |
| t4g.small for the collector and API     | $12                                                 |
| Egress                                  | first 100 GB free; CloudFront free tier covers 1 TB |
| **Total**                               | **~$102**                                           |

**300 GB and not 200.** An earlier version of this table said 200 GB, which does not fit: the
measured database is 163 GiB and the two projections the join-heavy endpoints need add about
56 GiB, so ~219 GiB is the real requirement before any growth headroom.

A t4g.xlarge (4 vCPU, 16 GB) on a 1-year reserved rate puts it at ~$124. Both fit the target.
Measured query memory was ≤25 MB, so 8 GB is not optimistic.

The unquantified risk is egress beyond the CloudFront free tier, which needs real API traffic
volume — Cloudflare analytics would give it, and Hasadna already uses Cloudflare for DNS.

### Stage 1 result: the org's stack runs, and the enrichment works

Ran the real repo — `goose` migrations and `dbt` models, not a hand-reconstructed schema —
against a local ClickHouse 26.10.1.

|                         |                       |
| ----------------------- | --------------------- |
| Migrations applied      | **6 of 6**, 0 pending |
| dbt models built        | **5 of 5**, 0 errors  |
| `ALIAS` columns present | 8                     |

The derived identities resolve correctly on real data:

```
siri_route_id:     7716;15
siri_ride_id:      7716;15;2022-06-13-2202082
siri_ride_stop_id: 7716;15;2022-06-13-2202082;37064;1
```

And this is the measurement that quantifies the architectural claim. For **one day**, the
entities PostgreSQL materializes as tables:

| Entity           | Distinct values in one day |
| ---------------- | -------------------------- |
| `siri_ride_stop` | **2,723,830**              |
| `siri_ride`      | 102,991                    |
| `siri_stop`      | 27,831                     |
| `siri_route`     | 6,677                      |

2.72 million rows a day that PostgreSQL's ETL writes and indexes are a `concat` expression
here, at zero storage.

Enrichment end to end, replacing the hourly `stride-etl-siri-add-ride-durations` UPDATE DAG:

|                                |              |
| ------------------------------ | ------------ |
| Duration rows computed         | 102,174      |
| Rides with a computed duration | 101,646      |
| Mean ride duration             | 53.6 minutes |

Under a second, via a materialized view plus a dated backfill.

### Three things stage 1 turned up

- **The migrations are hardcoded to the `default` database.** `limited_read_role.sql` does
  `GRANT SELECT ON default.*` and the skip-index migration does
  `alter table default.siri_vehicle_location`. They fail in any other database.
- **ClickHouse needs a writeable access storage** for `CREATE ROLE` to work — the official
  image gets this from `CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT: "1"`, so a Terraform-managed
  deployment has to configure a `local_directory` user directory explicitly or migration 5
  fails with `no writeable access storage in user directories`.
- **`limited_reader` is for the Stride API, not for the public.** Its env file says
  "read-only access from the Stride API". That makes the TimescaleDB licensing concern raised
  in §10 weaker than stated there — there is no plan to hand out direct SQL access.

### Mapping the 15 existing ETL processes

| Already written in the repo                | Stays as-is                | Drops                         | Must be built                          |
| ------------------------------------------ | -------------------------- | ----------------------------- | -------------------------------------- |
| `siri-add-ride-durations`                  | `siri-requester-daemon`    | `siri-storage-backup-cleanup` | **GTFS ingest**                        |
| `siri-update-ride-stops-gtfs`              | `gtfs-etl-download-upload` |                               | snapshot ingest loop                   |
| `siri-update-ride-stops-vehicle-locations` |                            |                               | validate / pending / missing-snapshots |
| `siri-update-rides-gtfs`                   |                            |                               | ride-aggregations, packagers           |

Four of the heavy DAGs already exist as dbt materialized views. The real build is GTFS.

**Blocking dependency found:** the existing ClickHouse POC is _not_ standalone. Its GTFS
macros read live from PostgreSQL via the `postgresql()` table function — `gtfs_ride`,
`gtfs_route` and `gtfs_stop`. A full migration has to build GTFS ingest regardless.

### Stage 4 result: the API contract, measured rather than read

The differential suite ran against production for the first time on 2026-11-03. It found six
defects, all of them in the reimplementation and none visible from reading the router source
alone. Each is recorded with how it was caught, because the pattern matters more than the
individual bugs: every one came from assuming a behaviour that one HTTP request would have
settled.

| Defect                                  | How it surfaced                       | Cause                                                                                                                                                                         |
| --------------------------------------- | ------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Three endpoints returned 500            | `/gtfs_routes/list?date_from=…`       | A `format: date` parameter was rendered as `'2026-05-20 00:00:00'` and compared against a `Date32` column. PostgreSQL casts this silently; ClickHouse raises `TYPE_MISMATCH`. |
| Wrong rows for an offset-bearing filter | `08:00+03:00` returned 08:00 UTC data | The offset was dropped instead of converted.                                                                                                                                  |
| An offset-less value was accepted       | —                                     | Production raises inside SQLAlchemy and answers 500 `tzinfo is required`.                                                                                                     |
| Every timestamp field lacked `+00:00`   | `/siri_snapshots/list`                | Upstream relabels naive values as UTC on read, so `isoformat()` appends an offset.                                                                                            |
| Microseconds truncated                  | `.464840` missing                     | 11 columns were loaded as `DateTime` rather than `DateTime64(6)`.                                                                                                             |
| No ordering without `order_by`          | `/siri_routes/list`                   | See below.                                                                                                                                                                    |

**Ordering is decided by the handler's declaration, not by the request.** This was first
misdiagnosed here as production running something other than `main`, which was wrong. The
code and the deployment agree; the four shapes simply differ per endpoint:

| Declaration                            | Endpoints                                      | Result                                            |
| -------------------------------------- | ---------------------------------------------- | ------------------------------------------------- |
| `param_order_by()`, default `'id asc'` | 8                                              | `ORDER BY id ASC`                                 |
| `param_order_by(default='')`           | `/siri_ride_stops/list`                        | empty falls through to the tiebreaker → `id DESC` |
| no `order_by` parameter at all         | 16                                             | `order_by=None` → tiebreaker → `id DESC`          |
| `skip_order_by=True`                   | `/route_timetable/list`, `/stop_arrivals/list` | no `ORDER BY`                                     |

Confirmed against production: `/siri_routes/list` returns `[1,2,3,4,5]`, `/gtfs_stops/list`
returns `[49899762, 49899761, …]`, and an `order_by` sent to `/gtfs_stops/list` changes
nothing, because FastAPI ignores a parameter the handler does not declare.

**Two datetime contracts, not one.** The published spec marks 22 parameters `format: date`
and 23 `format: date-time`, and they behave differently in every respect:

|                  | `format: date` (22) | `format: date-time` (23)            |
| ---------------- | ------------------- | ----------------------------------- |
| Accepts          | `YYYY-MM-DD` only   | ISO-8601 **with** an offset         |
| A full timestamp | 422                 | —                                   |
| A bare date      | —                   | 422 `invalid datetime format`       |
| No offset        | —                   | **500** `tzinfo is required`        |
| Offset handling  | n/a                 | converted to UTC, then stored naive |

The conversion was verified three ways: a `from` of `08:00+03:00` returns the same rows as
`05:00+00:00`, and different rows from `08:00+00:00`.

**Which columns need microsecond precision — a rule, from a full scan.** Scanning the source
data per column rather than widening everything:

| Origin                                                                                                                  | Columns | Fractional values | Type                     |
| ----------------------------------------------------------------------------------------------------------------------- | ------- | ----------------- | ------------------------ |
| Transport data — `arrival_time`, `departure_time`, `recorded_at_time`, `scheduled_start_time`, `start_time`, `end_time` | 8       | **0**             | `DateTime`, 4 bytes      |
| ETL writing about itself — `etl_*`, `updated_*`, `*_started_at`, `*_completed_at`, `last_heartbeat`, `created_at`       | 11      | essentially all   | `DateTime64(6)`, 8 bytes |

`gtfs_ride` and `siri_ride` were scanned in full (225M rows, exact); the two multi-billion-row
tables were sampled at 3M rows and then checked against current production data, where
`recorded_at_time` and `arrival_time` are still whole seconds. This matters because **none of
the 11 columns needing 8 bytes is in `siri_vehicle_location` or `gtfs_ride_stop`** — widening
every timestamp uniformly would have cost about 26 GB on `siri_vehicle_location` alone for
precision the data never carries.

**Mandatory-parameter guards**, which no amount of schema reading reveals — only
`gtfs_ride_stops.py` has them, and both answer 400:

- `arrival_time_from` and `arrival_time_to` are required
- the range between them may not exceed 30 days

**Load throughput, incidentally measured**: 110,227,936 rows of `siri_ride` from a zstd TSV in
**23 seconds** (4.8M rows/s), and `siri_vehicle_location` sustained ~930k rows/s. Every one of
the 15 completed tables matched the dump inventory exactly, row for row.

**Status**: 35/35 unit tests pass and **22 of 22 differential cases are byte-identical to
production**, across 13 of the 27 endpoints verified (20 of 27 registered) — including all four `/siri_vehicle_locations/list`
cases, whose four-way inner join runs over the full 6.5 billion rows. `/siri_rides/list` (29 fields, three joins, two of
them outer) and `/gtfs_rides/list` both matched on the first attempt once the defects above
were fixed, as did `/gtfs_ride_stops/list` including its three 400-level guards: the
`arrival_time` range requirement, the rule that a _single_ `gtfs_ride_ids` value waives it
while a comma-separated list does not, and the 30-day limit — which is `timedelta.days > 30`
upstream and therefore truncates, so 30 days plus a second passes and only 31 whole days
fails. Both sides were checked at that boundary. The remaining four are all `/siri_vehicle_locations/list` and are blocked on that
table being 17% loaded, not on the implementation.

Two classes of case are excluded by design, both artefacts of comparing against a growing
production from a fixed 2026-06-14 dump: unfiltered `get_count`, and unfiltered descending
order by id, which reads the newest rows — production's highest `/siri_routes/list` id is
19132 against 17846 here. A descending case bounded by a date filter is comparable and is
covered.

### Three more contract details, each of which only the source reveals

**An unknown `order_by` field is a 500, not a 422.** `order_by` resolves through
`getattr(db_model, field_name)`, so an unknown name raises `AttributeError` and production
answers `type object 'SiriRide' has no attribute 'bogus'`. The same mechanism means a related
table's field cannot be ordered by at all — only the base table's own columns — which is easy
to get wrong in the opposite direction by validating against the response schema.

**`gtfs_ride__start_time_to` filters `end_time`, not `start_time`.** In
`gtfs_rides.gtfs_ride_filter_params`, `start_time_from` is a `datetime_from` on
`GtfsRide.start_time` while `start_time_to` is a `datetime_to` on `GtfsRide.end_time`, so a
ride that merely overlaps the window qualifies. Reproduced as-is rather than corrected: the
goal is identical behaviour, and if this is a bug it is one that callers may already rely on.

**ClickHouse needs `join_use_nulls = 1` to reproduce an outer join.** By default an unmatched
`LEFT JOIN` row is filled with the column type's default, so a siri ride with no GTFS match
reported `gtfs_route__line_ref: 0` and `gtfs_route__agency_name: ""` where production reports
null. Verified on a window where all 8 rows are unmatched: with the setting, all 14 `gtfs_*`
fields come back null and the response is identical.

### Running the experiments without taking the machine down

The first full-speed load pushed the ClickHouse server to 994% CPU with 3.3 GB resident and
pushed the workstation into unresponsiveness. Every experiment now goes through one wrapper:

```bash
CORES=18-23                                      # 6 of 24
CAP="taskset -c $CORES nice -n 19 ionice -c 3"
CH="$CAP clickhouse client --max_threads=4 --max_insert_threads=2"
```

`taskset` is the part that matters: it pins the whole process tree, so it is a ceiling no
internal thread pool can exceed, unlike a settings-based limit. Measured after: 3.7% of the
machine against 1434% before, with the load still running at 1.1M rows/s.

`ionice` is set but has no effect here — the block devices use the `none` scheduler, where I/O
priority is not honoured, and cgroup v2's `io.max` needs root. Capping CPU was not enough: the
disk stayed saturated and the machine stayed slow, which is the part this first got wrong by
checking CPU, seeing 3.7%, and assuming the problem was solved.

What does work is ClickHouse's own bandwidth throttle, set in `config.xml`:

```xml
<max_local_read_bandwidth_for_server>83886080</max_local_read_bandwidth_for_server>   <!-- 80 MB/s -->
<max_local_write_bandwidth_for_server>41943040</max_local_write_bandwidth_for_server> <!-- 40 MB/s -->
<merge_tree>
  <max_bytes_to_merge_at_max_space_in_pool>2147483648</max_bytes_to_merge_at_max_space_in_pool>
</merge_tree>
```

The merge cap matters as much as the bandwidth: what saturated the disk was not the load but
**four background merges over 97 GiB of parts**, scheduled after the insert finished and still
running an hour later. Shrinking `background_pool_size` looks like the obvious fix but is
rejected at startup, because several other defaults
(`number_of_free_entries_in_pool_to_execute_mutation` at 20,
`…_to_execute_optimize_entire_partition` at 25) are checked against
`background_pool_size * background_merges_mutations_concurrency_ratio`. Capping the size of a
single merge avoids that whole class of inconsistency.

Measured during a full differential run against the loaded database:

|                          | Before    | After              |
| ------------------------ | --------- | ------------------ |
| Disk read + write        | ~300 MB/s | **3.9 + 6.5 MB/s** |
| NVMe utilisation         | 97.6%     | **3.6%**           |
| `io.pressure` full avg10 | 44%       | **0.01**           |

### `/gtfs_rides/list` does not work in production today

Measured while building the differential cases for it, not while looking for it:

| Query                                                              | Production                      | This implementation |
| ------------------------------------------------------------------ | ------------------------------- | ------------------- |
| `?gtfs_route__date_from=2026-05-20&gtfs_route__date_to=2026-05-20` | statement timeout               | **1.2s**            |
| `?start_time_from=…&start_time_to=…` (10-minute window)            | statement timeout after **64s** | **8.0s**            |
| `?gtfs_route_id=8953903`                                           | 0.26s                           | 0.28s               |

Two of the three filter shapes the endpoint publishes cannot be served at all; only the
indexed equality works. This is worth separating from the rest of the migration case, which
is about not regressing: here there is nothing to regress from. It also constrains the
differential suite, since a timeout gives nothing to compare, so those cases use the equality
filter and the timeout is recorded here instead.

### Why the last endpoints are not done: the sort key, not the row count

`/siri_ride_stops/list` is the hardest endpoint in the API — 56 response fields across seven
joins, five of them outer. It is registered but **not verified**, and the reason is a property
of the schema rather than a gap in the implementation.

Measured, each with a hard time cap so nothing ran away:

| Query                                                                          | Result     |
| ------------------------------------------------------------------------------ | ---------- |
| Full 7-join query, selective filter on the left                                | **> 60s**  |
| Just `siri_ride_stop LEFT JOIN siri_vehicle_location ON id`, same filter       | **> 60s**  |
| Same shape but the right table is `gtfs_ride_stop` (4.11B rows, `ORDER BY id`) | 5.28s      |
| `siri_vehicle_location WHERE id IN (5 real ids)`                               | **0.081s** |
| `gtfs_ride_stop WHERE id IN (3 real ids)`                                      | 0.005s     |

The third and fourth rows together are the diagnosis. Row count is not the problem: the
_larger_ table answers an id lookup in 81 milliseconds. What fails is the **join**, because
ClickHouse builds a hash table from the right-hand side and has no nested-loop-with-index plan
to fall back on. One such query had read 1.50 billion rows and allocated 2.14 GiB before it
was killed.

**The join is slow, not the lookup — and the join can be rewritten.** Writing the right-hand
side as a subquery pre-filtered by an `IN` over the same base selection makes ClickHouse prune
parts the way the standalone lookup does:

```sql
LEFT JOIN (
  SELECT id, lat, lon, recorded_at_time FROM prod.siri_vehicle_location
  WHERE id IN (SELECT nearest_siri_vehicle_location_id FROM prod.siri_ride_stop
               WHERE siri_ride_id IN (…))
) AS vl ON vl.id = rs.nearest_siri_vehicle_location_id
```

**> 60s → 0.059s**, in one statement, returning real rows. ClickHouse is capable of the plan;
it just does not choose it from a `JOIN` on its own. So the useful rule is not "joins are slow
in ClickHouse" but this:

| Join column                                                       | Behaviour                                           | Fix                                                      |
| ----------------------------------------------------------------- | --------------------------------------------------- | -------------------------------------------------------- |
| In the sort key (`siri_vehicle_location.id`, `gtfs_ride_stop.id`) | part pruning applies                                | rewrite the join as a pre-filtered subquery — **0.059s** |
| Not in the sort key (`gtfs_ride_stop.gtfs_ride_id`)               | full scan, 4.35s, and 4 GiB on the seven-join query | a skip index                                             |

For the second row the index type is not a free choice. Measured correlation between
`gtfs_ride_stop.id` and `gtfs_ride_id` is **-0.05** — no correlation at all, across 6 parts of
685M rows each — so a `minmax` index would prune nothing, and only a `bloom_filter` on the
column does anything useful.

**What this means for the migration decision:** the ClickHouse schema already committed in the
org's repo was designed for time-range scans, and the API's related-field joins need key
lookups it has no access path for. That is a gap in the schema, not a limit of the engine, and
the work it implies is specific: a bloom-filter index on the foreign keys the API joins on,
plus a query builder that emits the pre-filtered subquery form instead of a plain join.

**Production cannot serve this endpoint either** in the shape tested — the same filter times
out there after 68.9s. It does answer `?siri_ride_ids=<one id>` in 0.30s. So the comparison
that matters is between two systems that both need a narrow filter, not between a working
endpoint and a broken one.

### Is ClickHouse a bad fit because of joins? Measured answer: no

This deserves its own section because the first diagnosis above was too pessimistic, and the
correction came from measurement rather than from reading more documentation.

**Finding 1 — the lookup is fast; the join plan is the problem.** ClickHouse builds a hash
table from the right-hand side of a join and has no nested-loop-with-index plan. Writing the
right side as a subquery pre-filtered by `IN` restores pruning:

|                                                                               | Time       |
| ----------------------------------------------------------------------------- | ---------- |
| `siri_ride_stop LEFT JOIN siri_vehicle_location ON id`, selective left filter | **> 60s**  |
| Same, right side as a subquery with `WHERE id IN (…)`                         | **0.059s** |

**Finding 2 — every join needs it, not just the huge ones.** With only the 6.5-billion-row
join rewritten, the seven-join query still exceeded a 4 GB memory limit, because `gtfs_ride`
(115M rows) and `gtfs_stop` (35M) were being hashed whole. Each table is cheap on its own:
an `id` lookup is 0.002–0.004s on all six tables sorted by `id`.

**Finding 3 — a `bloom_filter` index is the wrong tool for an uncorrelated foreign key.**
`gtfs_ride_stop` is sorted by `id` and the API joins it on `gtfs_ride_id`, whose correlation
with `id` is **-0.05**:

|                                                          | Lookup time | Index size    |
| -------------------------------------------------------- | ----------- | ------------- |
| No index                                                 | 4.35s       | —             |
| `bloom_filter(0.01)`                                     | 2.23s       | 135 MiB       |
| `bloom_filter(0.0001)`                                   | 1.22s       | 263 MiB       |
| **`PROJECTION ... ORDER BY gtfs_ride_id, gtfs_stop_id`** | **0.015s**  | **29.87 GiB** |

The bloom filter stops at 3.6× because each granule of 8192 rows holds ~8192 distinct ride
ids, so the false-positive floor dominates however tight the filter is. The projection is
290× and `EXPLAIN` confirms why: it reads **3 granules out of 328,980**. Its cost is a second
sorted copy — 29.87 GiB against the base table's 24.57 GiB, and 1h56m to build under an
80 MB/s read cap.

**Finding 4 — the CTE is evaluated once per reference.** With all seven joins pre-filtered
the query returned correct rows in 48.8s. The cause was not any join: the `base` CTE takes
5.23s on its own (37,398 granules of 342,222, because `siri_ride_stop` is also sorted by `id`
while being filtered on `siri_ride_id`) and ClickHouse inlines rather than materialises it, so
it ran about eight times. Splitting it into two round-trips with literal id lists removes the
repetition entirely:

| Stage                                       | Time       |
| ------------------------------------------- | ---------- |
| 1 — base rows, one evaluation               | 5.23s      |
| 2 — all five wide tables by literal id list | **0.018s** |

**Conclusion.** The engine is not the limitation. Serving the API's related-field joins needs
two specific things, both nameable and both costed:

1. A query builder that resolves base rows first and fetches related tables by literal id
   list, rather than emitting one statement with seven joins.
2. A projection on each table whose foreign key is filtered but not sorted. Done and measured
   for `gtfs_ride_stop` (4.35s → 0.015s, +29.87 GiB). `siri_ride_stop.siri_ride_id` needs the
   same, which by the same pattern should take its 5.23s into the 0.02s range at roughly
   +26 GiB — **predicted from the measured case, not itself measured**.

That second point changes the storage figure materially: the 163 GiB whole-database number
above does not include projections. Two of them add roughly **56 GiB, taking the total to
about 219 GiB** — still far below PostgreSQL's 1.34 TB for one table, but the honest number to
put in front of the team is 219 GiB and not 163 GiB.

### Endpoint coverage

|                                  | Count | State                                          |
| -------------------------------- | ----- | ---------------------------------------------- |
| Verified identical to production | 13    | 22 of 22 differential cases pass               |
| Registered, not yet verified     | 7     | 6 `/get` endpoints and `/siri_ride_stops/list` |
| Not yet written                  | 7     | see below                                      |

The seven not written split cleanly. Two fit the existing query builder
(`/route_timetable/list`, `/stop_arrivals/list` — both use `skip_order_by`). Five are
hand-written SQL upstream and need a second mechanism, because the generic builder cannot
express them: `/gtfs_agencies/list` (a `GROUP BY` with a fixed `ORDER BY` and no `order_by`
parameter at all), `/gtfs_rides_agg/list`, `/gtfs_rides_agg/group_by`,
`/rides_execution/list`, and `/siri_velocity_aggregation/…`.

## 12. Still open

- **Real production table sizes** via `pg_total_relation_size`, which needs DB access. This
  is the one number that would turn §0's per-table figure into a whole-database figure, and
  it takes seconds for anyone with a psql connection:
  ```sql
  select relname, pg_size_pretty(pg_total_relation_size(c.oid)) as total,
         pg_size_pretty(pg_relation_size(c.oid)) as heap,
         pg_size_pretty(pg_indexes_size(c.oid)) as idx, n_live_tup
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  left join pg_stat_user_tables s on s.relid=c.oid
  where n.nspname='public' and c.relkind in ('r','m')
  order by pg_total_relation_size(c.oid) desc;
  ```
- **Q3 (the dashboard aggregation) was not measured** — it depends on the
  `gtfs_rides_agg_by_hour` materialized view, which the dump stores as a definition only.
- **A per-era bytes/row figure.** All volume numbers come from 2022 data. The same schema
  gave ~1.9× more bytes/row on 2026 data, though part of that gap is partitioning rather
  than the data, so the spread needs isolating before the 159 GB is treated as final.
- **Latency at production scale.** Measured at one day, roughly 1/1200 of the data.
- **Skip indexes for ClickHouse** to close the Q2 gap against PostgreSQL's B-trees.
- **The remaining 14 endpoints.** Five of them (`/gtfs_agencies/list`, `/gtfs_rides_agg/list`,
  `/gtfs_rides_agg/group_by`, `/rides_execution/list`,
  `/siri_velocity_aggregation/…`) are hand-written SQL rather than the generic query builder,
  so they need a second mechanism; the rest fit the builder already in place.
- **A migration story for `gtfs_ride_stop`** (4.11 billion rows) and `siri_ride_stop`
  (2.80 billion), which together are half the database and which no current plan covers.
