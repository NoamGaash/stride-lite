# Cost, resources, performance and tradeoffs

[עברית](DEPLOYMENT.he.md)

Five questions, answered with what was measured. Anything not measured is labelled.

---

## 1. What will it cost

**One VM, one disk, a CDN in front. ~$105/month in eu-west-1.**

| Resource | Size | Published rate | Monthly |
| --- | --- | --- | --- |
| EC2 `m7g.large` | 2 vCPU, 8 GB, Graviton | ~$0.091/h | **$66** |
| EBS `gp3` data volume | 400 GB | ~$0.092/GB-mo | **$37** |
| EBS `gp3` root volume | 20 GB | ~$0.092/GB-mo | **$2** |
| CloudFront | first 1 TB/month | free tier | **$0** |
| S3 reads | same-region | free | **$0** |
| **Total** | | | **~$105** |

Reserve the instance for a year and it drops to roughly $45, putting the total near **$84**.

**Why 400 GB.** Measured on the loaded database, with every projection built:

| | Size |
| --- | --- |
| Base tables, all 16 | **163.98 GiB** |
| `gtfs_ride_stop.by_ride` | 29.88 GiB |
| `siri_ride_stop.by_gtfs_stop` | 19.33 GiB |
| `siri_ride_stop.by_siri_ride` | 18.95 GiB |
| `siri_ride.by_natural_key` | 0.87 GiB |
| **Total** | **233.02 GiB** |

Projections are **30% of the footprint**, which is worth knowing before sizing a disk around
the 164 GiB that the data alone occupies.

**One of them can go.** `siri_ride_stop.by_gtfs_stop` exists only to make `/stop_arrivals/list`
fast, and that endpoint cannot return a row from production for any input — see
[FINDINGS.md](FINDINGS.md). Dropping it saves **19.33 GiB** and costs nothing anyone can
observe, taking the requirement to **213.69 GiB**.

EBS volumes grow online and never shrink, so there is no reason to buy the headroom up front.
250 GB fits the reduced footprint; 400 GB buys roughly four years at the measured +36 GiB/year
of base growth.

**Why one instance and not two:** ClickHouse's measured peak query memory was **≤25 MB** and
the API is a stateless Node process. They fit on one box with room to spare. `infra/main.tf`
provisions exactly one.

Two honest caveats:

- **The rates above are from AWS's published pricing pages and were not re-checked today.**
  Verify before anyone commits to them.
- **Egress above CloudFront's free 1 TB is the one unquantified risk.** It needs a real
  traffic figure, which Cloudflare analytics would give. Everything else here is bounded.

What the project pays today is not in this repository — that figure was reported privately.

### If the server is not on all the time

A different question with a different answer, and the answer is counter-intuitive: **the disk
is the bill and the compute is a rounding error.**

Stopping an EC2 instance stops the compute charge. Everything attached keeps billing. For a
server woken for about five hours a week — say a weekly working session — that is roughly
21.7 hours of compute a month:

| | Monthly |
| --- | --- |
| EBS `gp3` 250 GB, billed whether the instance runs or not | ~$22 |
| EBS `gp3` root, 20 GB | ~$2 |
| Public IPv4, billed even while the instance is stopped | ~$3.6 |
| EC2 `m7g.large`, 21.7 h | **~$2** |
| **Total** | **~$30** |

Two things follow.

**Size the instance up, not down.** Compute is under 7% of that bill. An `m7g.xlarge` with
four cores costs about $4 a month instead of $2 and halves every wait. Choosing a small
instance to save money saves nothing here.

**The public IPv4 is avoidable.** `infra/main.tf` already attaches an SSM role, so the instance
can be reached without one, for $3.6 less a month.

**Can five hours absorb a week of missed data?** Measured, ingest and enrichment together:
**14.7 s per hour of feed** — 9.8 s to pull the snapshots from S3 and 4.9 s to derive the typed
rows. A week is 168 hours of feed, so **about 41 minutes** on six throttled cores. Even
assuming an `m7g.large` is three times slower, that is two hours of a five-hour window, and
half of that on an `m7g.xlarge`.

### Keeping the history somewhere cheaper

If all of it must be present — which it must, for this to be the same API — there are three
shapes, and only one of them suits an intermittent server:

| | Storage, 233 GiB | Cost of a session |
| --- | --- | --- |
| **EBS, always provisioned** | ~$21 at $0.088/GB-mo | none; full speed |
| **ClickHouse reading S3 directly** | ~$5.6 at $0.024/GB-mo | every cold read is an HTTP GET, and a fresh instance has an empty cache |
| **S3 cold, restored to EBS per session** | ~$5.6 plus EBS while running | 30–60 minutes of the session, every session |
| **Tiered: recent on EBS, history on S3** | ~$9–12 | recent queries full speed, history slower |

Tiered storage is what ClickHouse is built for and the only one of these that keeps a
five-hour session useful while cutting the bill roughly in half. EBS **snapshots** look like
the obvious answer and are not: a volume restored from a snapshot loads its blocks lazily from
S3, so the first reads are slow exactly when they are needed, and Fast Snapshot Restore costs
far more than the storage it saves.

### Getting 233 GiB onto the machine in the first place

Loading the public dump on the instance takes **about 14 hours on six cores**, measured here,
and an `m7g.large` has two — so a day or more. That is cheap rather than slow in the sense
that matters: **the instance type is decoupled from the volume.** Rent a 32-core `c7g.8xlarge`
for the load alone, which should be a few hours and a few dollars, then stop it and bring the
same volume up under an `m7g.large`.

Faster still, if the uplink allows it: `BACKUP DATABASE … TO S3(…)` here and `RESTORE` there
copies a built database instead of re-parsing 13.7 billion rows, and skips rebuilding the four
projections. 233 GiB is about 33 minutes at 1 Gbps and about 5.5 hours at 100 Mbps. Transfer
into S3 is free.

---

## 2. What performs better, and what performs worse

Measured, same data, same machine.

### Better

| | PostgreSQL | ClickHouse | |
| --- | --- | --- | --- |
| Whole database on disk | ~1.4 TB for one table | **163 GiB for all 16** | 8.4× |
| Fleet-wide scan (Q1) | baseline | **5–8× faster** | |
| Growth per year | +307 GB | **+36 GB** | 8.5× |
| Join by a foreign key, with a projection | — | 4.35 s → **0.015 s** | 290× |
| One hour of SIRI ingest | — | **5–6 s** | |
| Re-running an already-loaded hour | — | **0 s** | |

### Worse

| | PostgreSQL | ClickHouse |
| --- | --- | --- |
| Selective `line_ref` + bounding box | **0.017 s** | 0.063–0.090 s |

That one is real and unfixed. A B-tree on `lon`/`lat` is simply the right tool for a narrow
geographic filter, and closing the gap needs skip indexes — work not yet done. It matters
because it is the map's query.

### Three sharp edges, each of which cost a day to find

1. **ClickHouse has no nested-loop-on-index join.** It hashes the right-hand side whole. A
   seven-table endpoint translated naively ran >60 s; rewritten as `IN` subqueries, **0.059 s**.
   Every join needs it, not just the big ones — `gtfs_ride` (115M) and `gtfs_stop` (35M)
   hashed whole blew a 4 GB limit.
2. **A CTE is inlined, not materialised.** A 48.8 s query turned out to be one 5.23 s base
   query running about eight times. Two round trips make the second stage **0.018 s**.
3. **`bloom_filter` is the wrong tool for an uncorrelated foreign key.** Correlation of `id`
   to `gtfs_ride_id` is **−0.05**, so every granule holds 8192 distinct values and the filter
   cannot discriminate: 4.35 s → 1.22 s at best, against 0.015 s for a projection.

---

## 3. Exact commands to run it locally

No Docker, no root, no package manager.

```bash
git clone https://github.com/NoamGaash/stride-lite && cd stride-lite
./up.sh
```

That is all of it. `up.sh` fetches the ClickHouse binary, starts it under the resource
ceilings in `ingest/local.xml`, creates the 16 tables and the raw landing table, installs the
ingest and enrichment chains, backfills two hours of live SIRI from S3, and starts the API on
:8080. `./up.sh 6` backfills six hours; `./up.sh 0` backfills none.

```bash
curl 'http://127.0.0.1:8080/siri_routes/list?limit=2'
cd api && npm test       # 35 unit tests, no DB needed
```

For the full 13.7-billion-row history instead of live data (~14 h, 164 GiB):

```bash
curl -O https://openbus-stride-public.s3.eu-west-1.amazonaws.com/stride_db.sql.zst
./scripts/load-from-dump.sh stride_db.sql.zst
```

Watch the ingest:

```sql
SELECT view, status, last_success_time, next_refresh_time, written_rows, exception
FROM system.view_refreshes;
```

Full detail, including how to keep the load from taking your machine down, is in
[LOCAL-DB.md](LOCAL-DB.md).

---

## 4. Exact cloud resources

**A VM, not a container service.** ClickHouse here is a stateful single node with a 300 GB
attached disk; ECS or Fargate would add an orchestration layer around one long-lived process
that never needs rescheduling. `infra/main.tf` provisions:

| Terraform resource | What it is | Why |
| --- | --- | --- |
| `aws_instance.app` | one `m7g.large`, 20 GB root | runs ClickHouse **and** the API |
| `aws_ebs_volume.data` + attachment | 400 GB `gp3` | the database; separate so the instance can be replaced under it |
| `aws_cloudfront_distribution.api` | CDN, 300 s default TTL | caches the repeated query strings the frontend issues, which bounds egress |
| `aws_security_group.api` | 80/443 open, SSH from `var.ssh_cidr` | `ssh_cidr` has no default on purpose |
| `aws_iam_role.instance` + SSM policy | instance profile | shell access via SSM, so no key to manage |

```bash
cd infra
terraform init
terraform apply -var ssh_cidr=YOUR.IP.ADDR.0/32
```

**Region: eu-west-1**, not by preference — the SIRI archive is already in that bucket, so
ingest reads are same-region and therefore free. Running elsewhere adds inter-region transfer
to every hour of ingest, forever.

**What is deliberately not here:** no RDS, no managed ClickHouse, no Kubernetes, no message
queue, no Redis, no Airflow. The scheduler is `REFRESH EVERY` inside the database and the
monitoring is `system.view_refreshes`.

---

## 5. Tradeoffs available

Ordered by how much they buy.

| Tradeoff | Gain | Cost |
| --- | --- | --- |
| **Add the four projections** | a foreign-key lookup on `siri_ride_stop` 44 s → 0.016 s, and the enrichment's ride lookup 6.83 GiB → 0.079 s | +69.04 GiB (163.98 → 233.02 GiB), ~25 min to build each under the local I/O cap |
| **Skip `by_gtfs_stop`** | −19.33 GiB, about $1.70/month of gp3 | nothing: the endpoint it serves cannot return a row from production |
| **Sort `siri_vehicle_location` by `vehicle_ref`** | 163 GiB → ~72 GiB, 2.2× smaller | per-vehicle queries win, time-range queries lose; the current sort is the safer default |
| **Refresh every 5 min instead of 1** | 5× fewer S3 list calls | data up to 5 min stale instead of 1 |
| **Drop the `previous`-hour view** | one object fewer | a missed refresh silently loses an hour until someone backfills |
| **S3 + Parquet as the durable layer, local cache for serving** | smallest footprint measured (99 GB) and DuckDB matched or beat ClickHouse on 2 of 4 queries | two engines to operate; Athena has a ~1 s planning floor, so it cannot serve the map directly |
| **Reserved instance, 1 year** | ~$96 → ~$75/month | a year of commitment |
| **Skip the CDN** | one resource fewer | egress becomes unbounded and unpredictable |
| **Keep PostgreSQL for the map's bbox query** | that one query stays at 0.017 s | two databases, which defeats the point; prefer skip indexes |

### The one that is not a tradeoff

**Do not drop `APPEND` from the refreshable views.** A refreshable materialized view without
it *replaces* its target's contents on every refresh. On an append-only archive that deletes
all history once a minute.

---

## What is not ready

Honest status, so nobody deploys this expecting a finished system:

- **27 of 27 endpoints** match production byte for byte, over 48 differential tests.
- **`gtfs_ride_stop` has no ETL.** It is loaded and measured but not kept current, and it is
  a quarter of the database on its own. `siri_ride_stop` is now maintained by the enrichment
  chain.
- **GTFS still ages from the dump.** SIRI flows end to end through
  `ingest/siri.sql` → `ingest/enrich.sql` → the API, but the daily GTFS refresh from
  `gtfs_archive/` is not built, and the enrichment macros still read GTFS out of PostgreSQL.
- **61 rows in a measured minute differ from production** in `scheduled_start_time`, for one
  vehicle with a sentinel journey ref. Cause not understood.
- **The `siri_ride_stop` projection is predicted, not measured.**
- **Catch-up throughput is measured; a 24-hour steady state is not.** Ingest and enrichment
  together cost 14.7 s per hour of feed, so a week of missed data takes about 41 minutes. RSS
  and CPU held over a full day of continuous running are still unmeasured.

[ROADMAP.md](../ROADMAP.md) tracks all of it.
