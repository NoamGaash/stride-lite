# Cost, resources, performance and tradeoffs

Five questions, answered with what was measured. Anything not measured is labelled.

---

## 1. What will it cost

**One VM, one disk, a CDN in front. ~$95–100/month in eu-west-1.**

| Resource | Size | Published rate | Monthly |
| --- | --- | --- | --- |
| EC2 `m7g.large` | 2 vCPU, 8 GB, Graviton | ~$0.091/h | **$66** |
| EBS `gp3` data volume | 300 GB | ~$0.092/GB-mo | **$28** |
| EBS `gp3` root volume | 20 GB | ~$0.092/GB-mo | **$2** |
| CloudFront | first 1 TB/month | free tier | **$0** |
| S3 reads | same-region | free | **$0** |
| **Total** | | | **~$96** |

Reserve the instance for a year and it drops to roughly $45, putting the total near **$75**.

**Why 300 GB:** the whole database measured **163 GiB**, and the two projections the
join-heavy endpoints need add **~56 GiB**, so ~219 GiB is the real requirement. 300 GB leaves
about two years of growth at the measured +36 GiB/year.

**Why one instance and not two:** ClickHouse's measured peak query memory was **≤25 MB** and
the API is a stateless Node process. They fit on one box with room to spare. `infra/main.tf`
provisions exactly one.

Two honest caveats:

- **The rates above are from AWS's published pricing pages and were not re-checked today.**
  Verify before anyone commits to them.
- **Egress above CloudFront's free 1 TB is the one unquantified risk.** It needs a real
  traffic figure, which Cloudflare analytics would give. Everything else here is bounded.

What the project pays today is not in this repository — that figure was reported privately.

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
# 1. ClickHouse: one static binary
curl https://clickhouse.com/ | sh
./clickhouse server --daemon

# 2. Schema — 16 tables
git clone https://github.com/NoamGaash/stride-lite && cd stride-lite
export CH_CLIENT="./clickhouse client"
./scripts/apply-schema.sh
./clickhouse client --database stride --multiquery < db/raw.sql   # the raw landing table

# 3. Data. Either live from S3 (public, no credentials, ~6 s per hour):
CH_DB=stride ./ingest/backfill.sh 2026 11 03
#    …or the full 13.7-billion-row history from the public dump (~14 h, 164 GiB):
curl -O https://openbus-stride-public.s3.eu-west-1.amazonaws.com/stride_db.sql.zst
./scripts/load-from-dump.sh stride_db.sql.zst

# 4. Continuous ingest — new snapshots arrive by themselves, no scheduler
./clickhouse client --database stride --multiquery < ingest/siri.sql

# 5. The API
cd api && npm ci && CH_DB=stride npm start      # http://127.0.0.1:8080
curl 'http://127.0.0.1:8080/siri_routes/list?limit=2'

# 6. Tests
npm test                                         # 35 unit tests, no DB needed
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
| `aws_ebs_volume.data` + attachment | 300 GB `gp3` | the database; separate so the instance can be replaced under it |
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
| **Add the two projections** | join-heavy endpoints 4.35 s → 0.015 s | +56 GiB (163 → 219 GiB), ~2 h to build each |
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

- **13 of 27 endpoints** match production byte for byte. 7 are registered but unverified,
  7 are unwritten (5 of those need hand-written aggregate SQL).
- **`gtfs_ride_stop` and `siri_ride_stop` have no ETL.** They are loaded and measured; they
  are not kept current. Together they are half the database.
- **The ingest is not wired to the API.** `ingest/siri.sql` lands the MOT feed in
  `siri_vehicle_location_raw` (all strings, no foreign keys). The API serves
  `siri_vehicle_location`, which is typed and joined by integer id and today comes from the
  dump. The materialized views that would derive one from the other are **not built**, so the
  pipeline is not end to end.
- **GTFS ingest is partial** — the enrichment macros still read GTFS out of PostgreSQL.
- **The `siri_ride_stop` projection is predicted, not measured.**
- **Resource figures under continuous ingest plus refresh have not been measured** for a
  sustained period. The ingest numbers above are per-hour, not a 24-hour steady state.

[ROADMAP.md](../ROADMAP.md) tracks all of it.
