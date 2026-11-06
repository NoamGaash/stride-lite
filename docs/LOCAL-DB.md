# Reproducing the local database

[עברית](LOCAL-DB.he.md)

Everything below runs against public data and needs no credentials. There is no
access to Hasadna's production database at any point, and none is needed.

**If you only want it running, `./up.sh` from the repository root does all of route B and
starts the API.** The rest of this page is for when you want the full history, or want to
know what each step does.

Two routes. Pick by what you want to do.

| | Route A — full dump | Route B — fixture day |
| --- | --- | --- |
| What you get | all 16 tables, 13.7 billion rows | one day of SIRI, ~5.5 million rows |
| Download | 154.6 GB compressed | ~1 GB |
| Disk after load | 164 GiB | ~130 MB |
| Wall time | ~14 h on 6 cores | ~10 min |
| Good for | the differential suite, storage figures | query work, API development |

## Prerequisites

- ClickHouse 25.3 or newer. No root, no Docker, no package manager needed:
  ```bash
  curl https://clickhouse.com/ | sh      # drops a single static binary in $PWD
  ./clickhouse server                    # listens on 9000 (native) and 8123 (HTTP)
  ```
- `zstd`, `mawk` (or any awk), `curl`.
- Node 22 for the API.

Point the scripts at your binary if it is not on `PATH`:

```bash
export CH_CLIENT="./clickhouse client --port 9000"
export CH_DB=stride
```

## Route A — the full dump

The production backup is public:

```bash
curl -O https://openbus-stride-public.s3.eu-west-1.amazonaws.com/stride_db.sql.zst
```

154,630,881,726 bytes, `pg_dump -n public --no-privileges | zstd -19`.

**It is stale.** `Last-Modified` is 2026-06-14 and the data inside ends 2026-05-29 — the
`stride-etl-db-copy-backup-to-s3` DAG last ran in 2022. That is a real operational problem
for the project (see [BENCHMARKS.md §10](BENCHMARKS.md)), and for our purposes it is simply
the window every differential test case has to stay inside.

```bash
./scripts/apply-schema.sh
./scripts/load-from-dump.sh stride_db.sql.zst
```

For live data on top of the dump, add the raw landing table, the ingest loop and the
enrichment:

```bash
./clickhouse client --database stride --multiquery < db/raw.sql
./clickhouse client --database stride --multiquery < ingest/siri.sql
./clickhouse client --database stride --multiquery < ingest/enrich.sql
```

From there the database keeps itself current: the feed lands in
`siri_vehicle_location_raw` and six chained refreshable views derive the API's typed tables
from it. After a backfill, run `ingest/enrich-once.sql` rather than waiting for the next
refresh. **Backfill oldest hour first** — a ride's `scheduled_start_time` is taken from its
earliest observation, so loading forwards gets the same answer the live loop would.

One streaming pass: `split-tables.awk` routes each `COPY` block to a per-table FIFO and 16
`clickhouse client` processes insert in parallel. Nothing is staged on disk, so you need room
for the dump plus ~164 GiB, not three times that.

Two things that are easy to get wrong and that the script handles:

- **Column order comes from the live schema**, queried at run time. The dump's `COPY` blocks
  are headerless, so a hand-written column list that drifts loads silently and wrongly.
- **`--date_time_input_format=best_effort`** is required. PostgreSQL writes microsecond
  timestamps that ClickHouse's default parser rejects.

Verify. The row counts are exact and should match to the row:

```sql
SELECT table, formatReadableQuantity(sum(rows)), formatReadableSize(sum(data_compressed_bytes))
FROM system.parts WHERE database = 'stride' AND active
GROUP BY table ORDER BY sum(data_compressed_bytes) DESC;
```

| Table | Rows | Compressed |
| --- | --- | --- |
| `siri_vehicle_location` | 6,506,195,421 | 111.52 GiB |
| `gtfs_ride_stop` | 4,113,193,845 | 24.57 GiB |
| `siri_ride_stop` | 2,803,456,736 | 21.24 GiB |
| `gtfs_ride` | 114,949,212 | 1.74 GiB |
| `siri_ride` | 110,227,936 | 2.58 GiB |
| `gtfs_stop` | 35,376,512 | 920 MiB |
| `gtfs_stop_mot_id` | 35,376,527 | 407 MiB |
| `gtfs_route` | 6,969,141 | 142 MiB |
| `siri_snapshot` | 2,246,550 | 137 MiB |
| 7 smaller tables | 60,113 | < 1 MiB |
| **Total** | **13,728,053,041** | **163.22 GiB** |

That is the dump as loaded and before any projection. Continuous ingest adds to it from there,
and the projections below are on top again.

Run `OPTIMIZE TABLE … FINAL` before you trust a size figure, or unsettled merges inflate it.

### Two projections, if you want the join-heavy endpoints to be fast

`/siri_ride_stops/list` and anything that filters a big table by a foreign key it is not
sorted by needs a second sort order. The measured one:

```sql
ALTER TABLE stride.gtfs_ride_stop
  ADD PROJECTION by_ride (SELECT * ORDER BY gtfs_ride_id);
ALTER TABLE stride.gtfs_ride_stop MATERIALIZE PROJECTION by_ride;
```

29.87 GiB and about two hours to build on 6 cores. It turns a 4.35 s lookup into 0.015 s by
reading 3 granules out of 328,980. A `bloom_filter` skip index is the wrong tool here and
only reaches 1.22 s — the reasoning and the numbers are in
[BENCHMARKS.md](BENCHMARKS.md#is-clickhouse-a-bad-fit-because-of-joins-measured-answer-no).

Budget for projections when you quote storage. Measured, all three:

| Table | Projection | Size | What needs it |
| --- | --- | --- | --- |
| `gtfs_ride_stop` | `by_ride` | 29.88 GiB | join-heavy endpoints |
| `siri_ride_stop` | `by_gtfs_stop` | 19.33 GiB | `/stop_arrivals/list` |
| `siri_ride_stop` | `by_siri_ride` | 18.95 GiB | `/siri_ride_stops/list` |
| `siri_ride` | `by_natural_key` | 0.87 GiB | the enrichment's ride lookup |

163.98 GiB base plus 69.04 GiB of projections is **233.02 GiB** — projections are 30% of it.
`siri_ride_stop` needs two because it is filtered by a different foreign key on each of two
endpoints and sorted by neither; each lookup goes from 44 s to 0.016 s. `siri_ride` needs one
because the enrichment asks "which of these rides already exist" every refresh, and without it
that question builds a 6.83 GiB set.

`by_gtfs_stop` is the one you can skip. It serves only `/stop_arrivals/list`, which cannot
return a row from production for any input — see [FINDINGS.md](FINDINGS.md) — so leaving it
out saves 19.33 GiB and changes nothing observable. All four are in
[`db/projections.sql`](../db/projections.sql).

## Route B — one fixture day

No dump. The raw SIRI snapshots are public and ClickHouse reads them from S3 directly, with
no application code in between:

```sql
SELECT count()
FROM s3('https://openbus-stride-public.s3.eu-west-1.amazonaws.com/stride-siri-requester/2026/05/20/08/{00..59}.br',
        NOSIGN, 'JSONEachRow', 'response String');
```

`NOSIGN` is not optional — without it ClickHouse refuses to use the server's credentials for
a user query.

For a loaded fixture day, the org's own repo has the ingest macro:

```bash
git clone https://github.com/hasadna/open-bus-stride-clickhouse
just data-ingest-backfill 2026 05 20 08
```

## Running the API against it

`scripts/apply-schema.sh` defaults to `CH_DB=stride`, so point it at whichever database the
API will serve (`CH_DB=prod ./scripts/apply-schema.sh`). It is what installs
`gtfs_rides_agg_by_hour_refresh`, and without that view the aggregate table is whatever was
loaded once and never recomputed — `/gtfs_rides_agg/group_by` then returns `[]` for any date
past the load, with no error to say why. `SELECT view, status, last_success_time FROM
system.view_refreshes` is where that shows up.

```bash
cd api
npm ci
CH_URL=http://127.0.0.1:8123 CH_DB=stride npm start   # listens on 8080
curl 'http://127.0.0.1:8080/siri_routes/list?limit=2'
```

```bash
npm test                                  # unit tests on SQL generation, no DB needed
npx vitest run tests/differential.test.ts # compares against the live production API
```

The differential suite calls `https://open-bus-stride-api.hasadna.org.il`, which is a
non-profit's production service and not a test environment. It spaces requests out by
`DIFF_DELAY_MS` (400 ms default) and keeps the case list small. Please leave it that way.

## Keeping your machine usable

The full load is an I/O-bound job that will take a workstation down if you let it. What
worked, after a first attempt that saturated the NVMe at 97.6% utilisation:

```bash
taskset -c 18-23 nice -n 19 ./scripts/load-from-dump.sh stride_db.sql.zst
```

`taskset` is the one that matters: it is a hard ceiling on the process tree that no internal
thread count can exceed. `ionice` does nothing on a `none` I/O scheduler, which is what NVMe
usually has — throttle inside ClickHouse instead:

```xml
<clickhouse>
  <max_local_read_bandwidth_for_server>83886080</max_local_read_bandwidth_for_server>
  <max_local_write_bandwidth_for_server>41943040</max_local_write_bandwidth_for_server>
</clickhouse>
```

Do not also lower `background_pool_size`: two internal sanity checks
(`number_of_free_entries_in_pool_to_execute_mutation` = 20 and
`..._to_execute_optimize_entire_partition` = 25) refuse to start the server if the pool is
smaller than they are.
