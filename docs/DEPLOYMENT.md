# Cost, resources, performance and tradeoffs

[עברית](DEPLOYMENT.he.md)

Five questions, answered with what was measured. Anything not measured is labelled.

---

## 1. What it costs

**One VM, one disk, a CDN in front: $3.24 a day, $98 a month in eu-west-1.** Under the $150
target, and under it on on-demand rates with nothing committed.

Every rate below comes from AWS's own published price list, effective **2026-11-01**, and is
checked into [infra/rates.json](../infra/rates.json). It is regenerated rather than
transcribed:

```bash
./scripts/fetch-rates.sh          # pulls the offer files and rewrites infra/rates.json
```

An estimate nobody can re-derive is an estimate nobody should act on, which is why this is a
script and not a paragraph.

### A day, with the server always on

| Service | What | Per day | Per month |
| --- | --- | --- | --- |
| EC2 | `m7g.large`, 2 vCPU, 8 GB Graviton, 24 h | **$2.18** | $66.43 |
| EBS | 300 GB `gp3`, the database | $0.87 | $26.40 |
| EBS | 20 GB `gp3`, root | $0.06 | $1.76 |
| VPC | one public IPv4 address | $0.12 | $3.65 |
| S3 | ingest requests, ~1,440 LIST + ~1,430 GET a day | $0.01 | $0.24 |
| CloudFront | inside the always-free 1 TB and 10 M requests | **$0** | $0 |
| | | **$3.24** | **$98.48** |

A one-year no-upfront reservation on the instance takes it to **$2.50 a day, $76 a month**.

### Where the money goes

| | Share |
| --- | --- |
| Compute | **67%** |
| Disk | 29% |
| IPv4 address | 4% |
| Everything else — S3, CDN, egress | **under 0.3%** |

Two consequences, and both run against instinct.

**The data pipeline is free.** Ingest, enrichment, scheduling and the CDN together are a
third of one percent of the bill. There is nothing to optimise there, and no case for choosing
a cheaper engine or a thriftier query. Reads of the archive are same-region and therefore
free, which is the whole reason for picking eu-west-1.

**The only lever that moves the number is whether the machine is on.** Not its size, not its
software. See below.

### Why 300 GB

Measured on the loaded database, with every projection built:

| | Size |
| --- | --- |
| Base tables, all 16 | **163.98 GiB** |
| `gtfs_ride_stop.by_ride` | 29.88 GiB |
| `siri_ride_stop.by_gtfs_stop` | 19.33 GiB |
| `siri_ride_stop.by_siri_ride` | 18.95 GiB |
| `siri_ride.by_natural_key` | 0.87 GiB |
| **Total** | **233.02 GiB** |

Projections are **30% of the footprint**, worth knowing before sizing a disk around the
164 GiB the data alone occupies. The live database measures **241.29 GiB** now that GTFS runs
daily rather than ageing from the dump.

**One projection can go.** `siri_ride_stop.by_gtfs_stop` exists only to make
`/stop_arrivals/list` fast, and that endpoint cannot return a row from production for any
input — see [FINDINGS.md](FINDINGS.md). Dropping it saves 19.33 GiB and costs nothing anyone
can observe.

EBS volumes grow online and never shrink, so there is no reason to buy headroom up front.
300 GB fits today with room for about a year and a half at the measured +36 GiB/year.

**Why one instance and not two:** measured peak query memory was **≤25 MB** and the API is a
stateless Node process. `infra/main.tf` provisions exactly one.

### Day one

Two ways to get 241 GiB onto the machine, and the cheap one is also the fast one.

| | AWS cost | Wall clock |
| --- | --- | --- |
| **Upload the built database** — `BACKUP … TO S3(…)` here, `RESTORE` there | **~$2** | bounded by your uplink: 35 min at 1 Gbps, 5.8 h at 100 Mbps |
| **Rebuild from the public dump on the instance** | $7–18 | hours; 14 h measured locally on six throttled cores |

Transfer **into** S3 is free, so the first path pays only for the backup sitting in S3 for a
day or two (~$0.36), the multipart PUTs (~$0.08), and an hour or two of instance time. Its
floor is EBS write throughput: `gp3` gives 125 MB/s at baseline, so 241 GiB cannot land in
less than **35 minutes** however fast the uplink is.

The second path needs no upload at all — the dump is in the same bucket and the same region,
so reading it is free — but it re-parses 13.7 billion rows and then rebuilds the four
projections, about 25 minutes each as measured locally. The instance type is decoupled from
the volume, so this is the one job worth renting a `c7g.8xlarge` for at $1.24/h and then
stopping.

Either way **day one is not where the money is.** The recurring bill is.

### If the server is not on all the time

A different question, with a counter-intuitive answer: **the disk is the bill and the compute
is a rounding error.** Stopping an EC2 instance stops the compute charge; everything attached
keeps billing. For a server woken about five hours a week — a weekly working session — that
is roughly 21.7 hours of compute a month:

| | Monthly |
| --- | --- |
| EBS `gp3`, 320 GB, billed whether the instance runs or not | $28.16 |
| Public IPv4, billed even while the instance is stopped | $3.65 |
| EC2 `m7g.large`, 21.7 h | **$1.97** |
| **Total** | **$33.78** |

**$34 a month, and 83% of it is the disk of a machine that is switched off.**

Two things follow. **Size the instance up, not down** — compute is 6% of that bill, so an
`m7g.xlarge` with four cores costs $4 instead of $2 and halves every wait. And **the public
IPv4 is avoidable**: `infra/main.tf` already attaches an SSM role, so the instance can be
reached without one, bringing it to **$30**.

**Can five hours absorb a week of missed data?** Measured, ingest and enrichment together:
**14.7 s per hour of feed** — 9.8 s to pull the snapshots from S3 and 4.9 s to derive the
typed rows. A week is 168 hours of feed, so **about 41 minutes** on six throttled cores. Even
assuming an `m7g.large` is three times slower, that is two hours of a five-hour window.

### Keeping the history somewhere cheaper

If all of it must be present — which it must, for this to be the same API — there are three
shapes, and only one suits an intermittent server:

| | Storage, 241 GiB | Cost of a session |
| --- | --- | --- |
| **EBS, always provisioned** | $21.21 | none; full speed |
| **ClickHouse reading S3 directly** | $5.54 | every cold read is an HTTP GET, and a fresh instance has an empty cache |
| **S3 cold, restored to EBS per session** | $5.54 plus EBS while running | 35+ minutes of every session |
| **Tiered: recent on EBS, history on S3** | $9–12 | recent queries full speed, history slower |

Tiered storage is what ClickHouse is built for and the only one that keeps a five-hour session
useful while roughly halving the bill. EBS **snapshots** look like the obvious answer and are
not: a volume restored from a snapshot loads its blocks lazily from S3, so the first reads are
slow exactly when they are needed, and Fast Snapshot Restore costs far more than the storage
it saves.

### Availability is not a requirement here, and that is a design decision

Stated by the project, and it simplifies this deployment more than any technical choice in it:
**the node may be down for days without anyone losing data.**

The reason is that the Python requesters — `open-bus-siri-requester` and the GTFS uploader —
are untouched by this work and keep writing to `s3://openbus-stride-public` whatever happens
here. S3 is the durable layer. **Everything in ClickHouse is derived**, and both loaders are
idempotent by date and by snapshot, so a node that has been dark for a week catches up by
reading forward: 41 minutes for the SIRI gap, 35 seconds per missed GTFS day.

So the database on this instance is a **cache, not a system of record**, and this module
deliberately contains:

| Not here | Why |
| --- | --- |
| EBS snapshots or any backup | the source is in S3 and the derivation is 41 min/week |
| A second instance, failover, a load balancer | downtime costs compute to recover, not data |
| Health alarms, paging, an on-call path | nothing to be woken up for |
| A budget alarm | **this one is here** — see below |

The asymmetry is the point. Downtime is recoverable with compute; **money spent is not
recoverable at all.** So `infra/main.tf` carries exactly one guard, `aws_budgets_budget`, at
50%, 80% and 100% of a `budget_usd` that defaults to the project's own $150 target.

What this does **not** cover: if the requesters stop, the archive stops, and nothing
downstream can recover what was never collected. That is the one dependency this design
genuinely has, and it lives in the existing infrastructure, not in this one.

### Measuring a real run, which the bill will not do

The plan is to point the frontend at this deployment for a few days and measure. Traffic
volume is the one input the whole cost model lacks — everything else here is measured — so
that is the right experiment. It has one trap.

**CloudFront's free tier is permanent: the first 1 TB and the first 10 million requests every
month.** A few days of real traffic will almost certainly fit inside it, so Cost Explorer will
report **$0** for the CDN and the number actually being sought will never appear on the
invoice.

So measure the bytes, not the bill:

```bash
cd infra && terraform output measure_cost_command     # prints the line below, filled in
scripts/measure-cost.py collect --distribution E… --instance i-… --days 3 > usage.json
scripts/measure-cost.py price usage.json
```

`collect` reads `BytesDownloaded` and `Requests` from CloudWatch; `price` needs no credentials
and reports the window, the projected month, and — the line that matters — **what the month
would cost if the free tier did not exist.** That figure says whether the free tier is a
ceiling this project will ever hit.

For scale: a 100-row response is **3,249 bytes gzipped**, so 1 TB is about 350 million
responses a month. If the map's responses are a hundred times larger, it is 3.5 million. The
gap between those two numbers is the entire question, and only real traffic closes it.

Three notes on running it:

- **Compression first.** Production ships its JSON uncompressed, 11.1x larger than it needs to
  be (finding 12). Measuring egress before fixing that measures the wrong system; this
  implementation compresses at the origin.
- **Pick representative days.** Benchmarking here was thrown off twice by sampling a Saturday
  and a war week, both about 5x off.
- **The fixed part is already exact.** Disk and instance are a flat line, known to the cent.
  The experiment only adds the variable part, which is currently under 1% of the bill.

Two caveats that remain:

- `running_hours` in `usage.json` is assumed, not measured: CloudWatch publishes no "was
  running" metric, so an instance stopped mid-window overstates its compute.
- What the project pays today is not in this repository. That figure was reported privately.

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
| `infra/bootstrap.sh` as `user_data` | installs ClickHouse, Node, the schema, the ingest chains and the GTFS cron | a launched instance serves the API with no further steps |
| `aws_budgets_budget.monthly` | alerts at 50/80/100% of `budget_usd` | the only unrecoverable failure here is spend |

```bash
cd infra
terraform init
terraform apply -var ssh_cidr=YOUR.IP.ADDR.0/32 -var budget_email=you@example.org
```

The bootstrap is idempotent except for creating the filesystem, which is guarded by `blkid`:
the data volume outlives the instance, and reformatting it is the one destructive step in this
repository.

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
- **The pipeline is complete.** SIRI flows `ingest/siri.sql` → `ingest/enrich.sql` → the API,
  and GTFS loads a day in 35 s through `ingest/gtfs.sh`. The database holds 1,405 consecutive
  days, 2023-01-01 to today.
- **`gtfs_ride_stop` is loaded but not refreshed.** It is a quarter of the database on its own
  and the daily GTFS loader replaces the rest of the GTFS tables, not this one.
- **Nothing has run unattended for 24 hours.** Ingest and enrichment cost 14.7 s per hour of
  feed, so a week of missed data takes about 41 minutes — but RSS and CPU held over a full day
  of continuous running are unmeasured, and that is the number a deployment should be sized on.
- **`/siri_velocity_aggregation` is not reproducible**, in production either — see
  [FINDINGS.md](FINDINGS.md) finding 5.
- **The `siri_ride_stop` projection is predicted, not measured.**

[ROADMAP.md](../ROADMAP.md) tracks all of it.
