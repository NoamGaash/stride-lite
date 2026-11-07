# Cost, resources, performance and tradeoffs

[עברית](DEPLOYMENT.he.md)

Five questions, answered with what was measured. Anything not measured is labelled.

---

## 1. What it costs

**One VM, one disk, a CDN in front: $2.72 a day, $83 a month in us-east-1.** Under the $150
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
| EC2 | `t4g.large`, 2 vCPU, 8 GB Graviton, 24 h | **$1.61** | $49.06 |
| EBS | 350 GB `gp3`, the database | $0.92 | $28.00 |
| EBS | 20 GB `gp3`, root | $0.05 | $1.60 |
| VPC | one public IPv4 address | $0.12 | $3.65 |
| S3 | ingest requests, ~1,440 LIST + ~1,430 GET a day | $0.01 | $0.24 |
| S3 | 254.57 GiB of Standard, the restorable copy of the database | $0.19 | **$5.86** |
| CloudFront | inside the always-free 1 TB and 10 M requests | **$0** | $0 |
| | | **$2.91** | **$88.41** |

A one-year no-upfront reservation on the instance takes it to **$2.30 a day, $70 a month**.

**The backup line is new and it buys one thing: a fresh instance that fills itself in an hour
instead of days, without reading a non-profit's bucket.** 7% of the bill. `-var
backup_bucket_enabled=false` removes it, and then every fresh instance rebuilds from public
data — reproducible, still correct, and the expense is no longer ours. See §"Day one".

### Where the money goes

| | Share |
| --- | --- |
| Compute | **55%** |
| Disk | 34% |
| The restorable copy in S3 | 7% |
| IPv4 address | 4% |
| Everything else — ingest requests, CDN, egress | **under 0.3%** |

Two consequences, and both run against instinct.

**The data pipeline is free.** Ingest, enrichment, scheduling and the CDN together are a
third of one percent of the bill. There is nothing to optimise there, and no case for choosing
a cheaper engine or a thriftier query. That also means same-region reads of the archive, which
used to be the reason for picking eu-west-1, are worth almost nothing: measured, the archive is
13.2 MiB per hour of SIRI, about 14 GB a month with GTFS, which is under $1.30 even at the
internet rate against $10.06 a month more for the same hardware in Ireland.

**The only lever that moves the number is whether the machine is on.** Not its size, not its
software. See below.

### Why 350 GB

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
164 GiB the data alone occupies.

Re-measured on the live database on **2026-11-07**: **180.43 GiB of base tables and 74.14 GiB
of projections, 254.57 GiB served**, across 7.14 billion vehicle locations. Two things changed
it since the dump figure above. GTFS runs daily instead of ageing from the dump, and the SIRI
landing rows are now **kept** rather than dropped per month — `siri_vehicle_location_raw` is
3.12 GiB today and grows 2.80 GiB a month (measured: 133.76M rows for 2026/08), which is the
price of being able to repair a day without a second download out of Hasadna's bucket.

**That 254.57 GiB is not a complete history**, and a disk sized from it would be sized from a
gap: September and October 2026 were never loaded, and most of November is missing. About
10 GiB of vehicle locations and their projections, so call a complete history **265 GiB**.

So 350 GB — 326.0 GiB usable — leaves about **61 GiB**. At the measured +36 GiB a year of typed
tables *plus* 33.6 GiB a year of landing rows, that is **ten months, not the sixteen** the
typed tables alone suggested. 300 GB is 279.4 GiB and would be full on arrival with nothing for
a merge to work in.

**The first load needs no headroom beyond that figure**, which is the thing worth knowing before
raising it: `scripts/load-from-dump.sh` streams, so the 144.01 GiB dump is never on the disk.
Staging it would need 398 GiB, which is not a size this volume can be.

**One projection can go.** `siri_ride_stop.by_gtfs_stop` exists only to make
`/stop_arrivals/list` fast, and that endpoint cannot return a row from production for any
input — see [FINDINGS.md](FINDINGS.md). Dropping it saves 19.33 GiB and costs nothing anyone
can observe.

EBS volumes grow online and never shrink, so there is no reason to buy headroom up front:
sizing for a year and raising it later is strictly cheaper than sizing for three.

**Why one instance and not two:** measured peak query memory was **≤25 MB** and the API is a
stateless Node process. `infra/main.tf` provisions exactly one.

### Day one

Three ways to get 255 GiB onto the machine, and the question is not only what it costs us —
reading `s3://openbus-stride-public` is billed to **Hasadna**, so two of the three spend
somebody else's money.

Everything below is measured. The archive was measured by unsigned `LIST` on **2026-11-07**, so
no object bytes were moved to measure it: **288,970,717,345 bytes (269.1 GiB) in 2,794,246
objects**, 2021/04 to 2026/11. The dump is **154,630,881,726 bytes**, `Last-Modified`
2026-06-14, and the data inside it ends 2026-05-29. Transfer rates are from AWS's own
`AWSDataTransfer` offer file, fetched the same day: out of eu-west-1, **$0.02/GB to another AWS
region, $0.09/GB to the internet**, and the `AmazonS3` eu-west-1 offer file carries no
same-region transfer line at all — a reader in eu-west-1 costs the owner nothing but requests,
at $0.0004 per 1,000 GETs.

| | To Hasadna | To us | Wall clock |
| --- | --- | --- | --- |
| **(c) `RESTORE` our own copy** | **$0** | $5.86/month of S3 Standard while it sits there | 35 min floor, see below |
| **(a) Stream the public dump, then backfill the 162 days after it** | $3.66 of transfer + $0.09 of GETs from us-east-1; **$0.09 from eu-west-1** | $0 | hours to days, see below |
| **(b) Backfill the whole archive, no dump** | $5.78 of transfer + **$1.12 of GETs** | $0 | **190 h at the measured 337 s/day** |

**(c) wins on every axis and it is what `first-load.sh` prefers.** Transfer *into* S3 is free
and an in-region read out of S3 to EC2 is free, so a restore costs the storage while the copy
sits there and nothing else. Its floor is EBS write throughput: `gp3` gives 125 MB/s at
baseline, so 255 GiB cannot land in less than **35 minutes** however fast the source is. It
also skips the one cost the other two cannot: there is nothing to parse and no projection to
build, because `BACKUP` carries the projection parts — verified on 26.10, a backed-up and
restored table came back with its projection populated.

The catch is that (c) is not reproducible from public data: somebody has to have built it. So
the design is both — **(a) once, ever, and (c) from then on.** The first instance rebuilds from
public data and then publishes a backup to our own bucket; every later instance restores from
there and never touches the public bucket in bulk. That is what makes the $3.66 a one-off
rather than a per-instance cost, and it is the whole reason `var.backup_bucket_enabled`
defaults to true.

**(b) is the one to avoid**, which is worth saying because it is the obvious-looking answer:
the archive is the system of record, so why not read it? Because 2.8 million HTTP GETs at
337 s/day is **eight days** of fetching, it costs Hasadna more than the dump does in transfer
*and* twelve times as much in requests, and it ends up at the same rows the dump already holds.
It is the right tool for the 162 days the dump does not cover, and the wrong one for the four
years it does.

**On (a)'s wall clock, honestly: not measured on this hardware, and the local figure does not
transfer.** 14 h on six throttled cores is what `docs/LOCAL-DB.md` measured for the parse; a
`t4g.large` has two vCPUs and a 30% baseline, so a job that pins them for a day will exhaust
its CPU credits and then run at baseline. The instance type is decoupled from the volume, so
this is the one job worth renting a `c7g.8xlarge` for — `-var instance_type=c7g.8xlarge` at
$1.16/h, then set it back, which stops and starts the instance without touching the volume.

**(a) streams and cannot stage.** 144.01 GiB of dump plus 254.57 GiB of loaded data is 398 GiB,
and the volume is 326 GiB: staging the dump is not slower there, it is impossible. So
`scripts/load-from-dump.sh` takes a URL and pipes it straight into 33 parallel inserts. The
price of that is no resume — an interrupted stream starts over, and over somebody else's
egress — which is one more reason the first instance publishes a backup the moment it succeeds.

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
| EBS snapshots | a volume restored from a snapshot loads its blocks lazily from S3, so the first reads are slow exactly when they are needed, and Fast Snapshot Restore costs more than the storage it saves |
| A second instance, failover, a load balancer | downtime costs compute to recover, not data |
| Health alarms, paging, an on-call path | nothing to be woken up for |
| A budget alarm | **this one is here** — see below |

**One thing this table used to rule out is now here, and the reason the argument above does not
cover it: a restorable copy of the database in S3.** The argument above is about *losing* a
node, and it still holds — the node is derived and the archive is the system of record.
`var.backup_bucket_enabled` is about *filling* one. Recovering a week of gap is 41 minutes of
compute; recovering the whole history from public data is days of compute and $3.75 of
Hasadna's money, and the copy turns that into 35 minutes and nothing. It is not insurance. It
is the first load, and §"Day one" has the numbers.

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

For the full 13.7-billion-row history instead of live data (~14 h on six throttled cores,
164 GiB):

```bash
curl -O https://openbus-stride-public.s3.eu-west-1.amazonaws.com/stride_db.sql.zst
./scripts/load-from-dump.sh stride_db.sql.zst
```

Keeping the file is worth the 144 GiB locally, because a reload then costs nothing and reaches
no network. Where it is not — a cloud volume that cannot hold both — the same script takes the
URL and streams it, staging nothing:

```bash
./scripts/load-from-dump.sh https://openbus-stride-public.s3.eu-west-1.amazonaws.com/stride_db.sql.zst
```

**Please do not run either twice.** 154.63 GB comes out of a non-profit's bucket each time.

Watch the ingest:

```sql
SELECT view, status, last_success_time, next_refresh_time, written_rows, exception
FROM system.view_refreshes;
```

Full detail, including how to keep the load from taking your machine down, is in
[LOCAL-DB.md](LOCAL-DB.md).

---

## 4. Exact cloud resources

**A VM, not a container service.** ClickHouse here is a stateful single node with a 350 GB
attached disk; ECS or Fargate would add an orchestration layer around one long-lived process
that never needs rescheduling. `infra/main.tf` provisions:

| Terraform resource | What it is | Why |
| --- | --- | --- |
| `aws_instance.app` | one `t4g.large`, 20 GB root | runs ClickHouse **and** the API |
| `aws_ebs_volume.data` + attachment | 350 GB `gp3` | the database; separate so the instance can be replaced under it |
| `aws_cloudfront_distribution.api` | CDN, 300 s default TTL | caches the repeated query strings the frontend issues, which bounds egress |
| `aws_security_group.api` | port 80 in, nothing else | there is no key pair, so there is nothing for port 22 to admit |
| `aws_iam_role.instance` + SSM policy | instance profile | shell access via SSM, so no key to manage |
| `aws_s3_bucket.backup` + a role for ClickHouse to assume | `stride-lite-backup-<account-id>` | the restorable copy of the database, so a fresh instance fills itself in an hour. `prevent_destroy`, for the same reason the data volume has it |
| `aws_acm_certificate.api`, when `api_domain` is set | a certificate in us-east-1 | CloudFront reads certificates from there and nowhere else |
| `infra/bootstrap.sh` as `user_data` | installs ClickHouse, Node, the schema, the crons, and starts the first load | a launched instance serves the API, and fills itself, with no further steps |
| `aws_budgets_budget.monthly` | alerts at 50/80/100% of `budget_usd` | the only unrecoverable failure here is spend |

```bash
cd infra
terraform init
terraform apply -var budget_email=you@example.org
```

The bootstrap is idempotent except for creating the filesystem, which is guarded by `blkid`:
the data volume outlives the instance, and reformatting it is the one destructive step in this
repository.

**Region: us-east-1**, because it is the cheapest and that is the recorded priority —
README.md §"Who decided what" carries "Cheapest wins, some performance loss is acceptable", and
that is the line that ruled out eu-west-1 for same-region reads. It was decided on steady state
alone, so here it is re-priced against the bulk load, which is the thing it did not cover.

The archives are in `s3://openbus-stride-public` in eu-west-1, and **S3 transfer out is billed
to the bucket's owner**, so this choice decides what a non-profit pays. Rates from AWS's
`AWSDataTransfer` offer file, fetched 2026-11-07: out of eu-west-1, **$0.02/GB to another AWS
region, $0.09/GB to the internet**, and the `AmazonS3` eu-west-1 offer file has no same-region
line at all, so a reader in eu-west-1 costs the owner nothing but requests. Measured volumes:
the dump is 154,630,881,726 bytes, and the whole SIRI archive is 288,970,717,345 bytes
(269.1 GiB) in 2,794,246 objects — measured by `LIST` on 2026-11-07, so no bytes were moved to
measure it. October 2026 alone is 5.37 GiB in 44,293 objects, about **7.4 MiB an hour of feed**
and not the 13.2 MiB this repository used to quote.

| | us-east-1 | eu-west-1 |
| --- | --- | --- |
| First load: dump + the 162 days after it, **to Hasadna** | $3.66 transfer + $0.09 requests | **$0.09** |
| Steady-state ingest, **to Hasadna** | $0.13/month | $0.02/month |
| The same instance and disk, **to us** | — | **+$10.06/month** |

So eu-west-1 would spend **$120.72 a year of this project's money to save $3.75 of Hasadna's,
once, and $1.32 a year after that.** That is why us-east-1 stays, and the reason it is
defensible rather than merely cheaper is that the $3.75 is paid **once ever and not once per
instance**: `scripts/first-load.sh` publishes the built database to our own bucket, and every
later instance restores from there without reading the public bucket in bulk at all.

If even that one-off is worth avoiding, the lever is per-instance rather than permanent: run
the instance that does the public rebuild with `-var region=eu-west-1`, let it publish, and the
copy it leaves behind is what everything after it reads.

What us-east-1 costs us is latency on a CloudFront cache miss, with the origin in Virginia
rather than Ireland; that is a minority of requests under a 300 s TTL on repeating query
strings, and **it is still not measured from Israel.**

### A name the frontend can actually reach

`output "api_url"` is a `*.cloudfront.net` name until `var.api_domain` is set, and that is not
merely untidy: the frontend's production CSP allows `connect-src https://*.hasadna.org.il` and
nothing else, enforced identically in its `csp.ts` and `nginx-default.conf` with a test
asserting the two match byte for byte. So the frontend's `VITE_STRIDE_LITE_API` opt-in
(hasadna/open-bus-map-search#1929) **cannot be switched on against the default name at all**,
whatever is put in the variable. Either this deployment gets a name in that zone, or two files
in the frontend change; the first touches nobody else's repository.

Setting `-var api_domain=stride-lite.hasadna.org.il` makes Terraform request an ACM certificate
in **us-east-1 regardless of `var.region`** — CloudFront reads certificates from there and
nowhere else — attach it to the distribution as an alias with `sni-only` and a
`TLSv1.2_2021` floor, and then wait for DNS validation.

**Two records are needed from whoever controls the `hasadna.org.il` zone**, which is Cloudflare
under `hasadna-iac`:

| | |
| --- | --- |
| the ACM validation record | `terraform output acm_validation_records` prints its name, type and value |
| `stride-lite.hasadna.org.il` CNAME to the distribution | `terraform output api_origin_url` is the host |

Both **DNS-only, not proxied**: an orange-cloud record puts Cloudflare's CDN in front of
CloudFront, which is a second cache, a second TLS termination and a second place to debug.

The apply **blocks** until the validation record exists — `aws_acm_certificate_validation` with
a 60-minute timeout. That is the intended shape: the alternative is an apply that succeeds and
a distribution serving a certificate for a name nobody can resolve. The health check in
`deploy.yml` uses `api_origin_url` and not `api_url` for the same reason — whether somebody
else has added a DNS record is not a condition of our deploy succeeding.

### Deploying from CI, and what has to exist first

`.github/workflows/deploy.yml` runs on every push to `main`. It does two things, because they
are two things and only the first is Terraform's:

1. `terraform plan` and `terraform apply`, which converges the AWS resources above.
2. `scripts/deploy.sh` on the instance, sent over SSM, which is what actually puts new code
   there.

The second step is not redundant. `bootstrap.sh` is `user_data`, so it runs once per instance
launch, and `user_data_replace_on_change = false` is deliberate: a push must not replace the
instance, because the 400 GB volume and the hours of backfill on it are the expensive part.
Without step 2 a push would change nothing a user can see. SSM is the channel because it is
already there — there is no key pair and no open port 22.

Four things have to exist before the first run, and none of them are in this repository
because they are account-specific:

| | What |
| --- | --- |
| An S3 bucket named `stride-lite-tfstate-<account-id>` | Terraform state. With local state every CI run starts from nothing and tries to create what exists |
| GitHub as an OIDC identity provider in the account | One entry, shared by anything this account ever trusts GitHub for |
| A role trusting `infra/github-oidc-trust.json`, carrying `infra/deployer-policy.json` | What CI becomes. There is no access key, here or in the repository settings |
| Variables `TF_STATE_BUCKET` and `AWS_ROLE_ARN` | Repository **variables**, not secrets: the workflow gates on both, so a value put in secrets leaves the job skipping silently. `AWS_REGION` is optional — unset, the workflow uses `us-east-1` |

**There are no secrets to set.** The job presents the token GitHub mints for it and gets
credentials that expire when the run ends, so there is nothing to rotate, nothing to leak and
nothing to remember to delete. An access key would work too, and is what this started as; it is
a long-lived credential for an account, and the reason to prefer it was never a good one.

Two details decide whether the trust policy matches, and both fail the same silent way —
`AssumeRoleWithWebIdentity` is simply not authorized, with nothing said about which claim
disagreed:

- **The job names an environment, so `sub` ends in `:environment:aws`**, not
  `:ref:refs/heads/main`. A trust policy written around the branch never matches.
- **A repository created after 2026-07-15 gets the immutable `sub` format**,
  `repo:OWNER@OWNER-ID/REPO@REPO-ID:...`. This one was created 2026-11-03, so that is the form
  it sends. The trust policy accepts both spellings of the same repository and pins it by
  numeric id, which no rename can change.

Setting it up, with the account id derived rather than filled in:

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

# IAM fetches the provider's certificate thumbprint itself; only the URL is required.
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com

sed "s|\${ACCOUNT}|$ACCOUNT|" infra/github-oidc-trust.json > /tmp/trust.json
aws iam create-role --role-name GitHubActionsStrideLiteDeployer \
  --assume-role-policy-document file:///tmp/trust.json
aws iam put-role-policy --role-name GitHubActionsStrideLiteDeployer \
  --policy-name StrideLiteTerraformDeployer \
  --policy-document file://infra/deployer-policy.json

aws iam get-role --role-name GitHubActionsStrideLiteDeployer \
  --query Role.Arn --output text   # this is the AWS_ROLE_ARN variable
```

**The role's name deliberately does not start with `stride-lite-`.** `deployer-policy.json`
grants `iam:DeleteRole` over `role/stride-lite-*`, so a role named inside that prefix would be
able to delete itself.

The bucket is named after the account rather than freely, because S3 bucket names are globally
unique: a fixed name would already be taken, and a free one would be a value the policy cannot
know. So the policy scopes to `stride-lite-tfstate-*`, and this derives the name instead of
asking you to invent one:

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BUCKET="stride-lite-tfstate-$ACCOUNT"

aws s3 mb "s3://$BUCKET" --region us-east-1
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
echo "$BUCKET"   # this is the TF_STATE_BUCKET variable
```

**The region appears in two places that have to agree.** `aws:RequestedRegion` in the policy is
`us-east-1`, matching `var.region`'s default. Running in another region means changing both, or
every EC2 call is denied — which fails confusingly, because the plan reads fine and only the
apply breaks.

The workflow names a GitHub environment, `aws`. Putting a required reviewer on it is what
turns "every push deploys" into "every push asks first", and it is one checkbox.

The policy is scoped where scoping means something: state access is the one bucket and one
prefix, IAM is `stride-lite-*` only, EC2 is conditioned on the region, and `ssm:SendCommand`
is conditioned on `Project=stride-lite` so these credentials cannot run a command on any other
instance in the account. It is broad on `ec2:Describe*` and on CloudFront, because a plan reads
the account and CloudFront's API carries no useful resource conditions. What it is not scoped
by is time, and it does not need to be: the credentials the role hands out last as long as the
run and the trust policy admits one repository.

### What the first deploy leaves you with

**The whole history, without anybody running a command.** That is new, and this section used to
say the opposite — "a working API over a nearly empty database, and that is not a bug to chase".
It was a bug, and this is what it was: `bootstrap.sh` applied the schema and started the
refreshable views, which read the running hour from S3, so data accumulated from go-live forward
and nothing before it existed. `ingest/catchup.sh` refuses an empty database on purpose ("a
first load is `./up.sh`, not a catch-up"), because it walks forward from the newest snapshot
actually loaded and there was none. Nothing loaded history. A deploy produced an API that
answered every query with an empty list.

`infra/bootstrap.sh` now ends by starting `stride-first-load.service`, a `oneshot` unit that
runs [`scripts/first-load.sh`](../scripts/first-load.sh) once. Five stages, each skipped when
the state file on the data volume says it finished:

| Stage | What it does |
| --- | --- |
| `history` | everything up to the dump's last day: `RESTORE` from our own S3 copy if there is one, otherwise stream the public dump |
| `gtfs` | yesterday's feed, which the dump's GTFS tables stop short of |
| `live` | `ingest/siri.sql`, `ingest/enrich.sql`, `ingest/health.sql` — the chain that keeps it current from here |
| `backfill` | `ingest/backfill-range.sh` from the history watermark to today |
| `publish` | `BACKUP` to our own bucket, so no later instance repeats the public rebuild |

Five properties, each of which is the answer to a way this can go wrong.

**It is resumable, and the state lives on the data volume.** `/var/lib/clickhouse/first-load.state`
is one append-only line per stage, so the file reads as a log of what happened and when. The
volume is the right lifetime: it outlives the instance exactly as the data it describes does, so
replacing the instance under it does not restart a load that finished. `Restart=on-failure` with
`RestartSec=600` retries, and `TimeoutStartSec=infinity` is not decoration — the default start
timeout is 90 seconds and this job is measured in hours.

**It does not run alongside the ingest.** The unit takes `/var/lock/stride-catchup`, the lock the
hourly `catchup.sh` cron already uses with `flock -n`, so a tick during a first load does not
run rather than queueing behind it. `scripts/deploy.sh` takes the same lock with a ten-minute
wait and, if it cannot get it, updates the code and leaves the schema to the next deploy.

**The live chain is installed after the history, not before.** The dump carries its own `id`
values and the enrichment mints ids as `max(id) + row_number()`; both writing at once hands one
id to two different readings, which is the failure that cost this project twenty-nine days of
data. On a retry — where the chain is already up — the history stage stops it, waits for the
refresh in flight, and starts it again.

**It refuses to empty a database it has no record of loading.** A retry of the history stage
truncates the data tables, because `RESTORE` will not write into a table that already holds rows
(measured: `CANNOT_RESTORE_TABLE`) and a stream that died half way leaves part of itself behind.
So a populated database with no state file stops the script rather than being emptied by it. CI
asserts this one, because it is the only failure mode here that destroys rather than delays.

**It asks whether a backup exists before trying to restore one.** An absent backup means rebuild
from public data; a broken one means stop and look; and a failed `RESTORE`'s exit code does not
tell them apart. On the first instance ever the bucket is empty, so the answer is no.

Watching it:

```bash
aws ssm send-command --instance-ids "$ID" --document-name AWS-RunShellScript \
  --parameters commands='["systemctl status stride-first-load --no-pager","cat /var/lib/clickhouse/first-load.state","tail -40 /var/log/stride-first-load.log","curl -fsS http://127.0.0.1/status"]'
```

The `deploy` workflow prints the same three things into its job summary, so an ordinary push
reports where the load got to. It is not a gate: a node still loading history is a working
deploy, and that is the design.

### Schema changes

Three kinds, and only one of them needs a migration.

| Change | How it reaches a running database |
| --- | --- |
| A new table | `db/schema.sql`, `CREATE TABLE IF NOT EXISTS` — appears on the next deploy |
| Any view, including the refreshable ones | `CREATE OR REPLACE`, so the file is always what the database holds |
| A change to a table that already holds data | a numbered file in `db/migrations/`, run once, recorded in `schema_migrations` |

The second row is a correction, not a design. These were `CREATE MATERIALIZED VIEW IF NOT
EXISTS`, and measured on ClickHouse 26.10 a changed body under `IF NOT EXISTS` is **accepted
and silently discarded** — no error, no warning, and the file and the database drift apart with
nothing to say so. That is exactly how `gtfs_rides_agg_by_hour` sat frozen at the dump's last
day while the differential suite stayed green. CI now asserts the opposite: it applies a
changed view body and fails if the database does not take it.

Two measurements that made `CREATE OR REPLACE` safe to use here rather than assumed to be:

- On an **APPEND** refreshable view it preserves the target. A target holding 3 rows held 5
  after a replace — the originals plus one immediate refresh — and every view in the ingest and
  enrichment chains is idempotent by `NOT IN`, so that extra pass writes nothing.
- On a **non-APPEND** one it replaces the target's contents, because that is what a refresh of
  such a view does. The only one here is `gtfs_rides_agg_by_hour_refresh`, whose refresh is a
  92-second full rebuild it performs every 6 hours regardless.
- Replacing a view that others `DEPENDS ON` keeps the dependency: the dependent still declares
  it afterwards and both stay `Scheduled`.

Tables cannot work that way, because they hold the data. `db/migrations/README.md` has the
three rules; the one that matters is that ClickHouse DDL has no transaction and no rollback, so
each statement is written to be safe to re-run after a failure half way.

### What can be public, and what cannot

The project is open and so is this repository, and most of what an operator would want to see
can be public. One thing cannot, and it is the one that is tempting.

**Already public, because the repository is:** every measurement and finding in `docs/`, the
cost model (it is derived from AWS's published price list, not from a bill), `infra/` including
`bootstrap.sh`, and the Actions logs of every run. The API itself is meant to be public — it
serves ministry data that is already public — and so is the data.

**Safe to publish, and worth it:**

| | Why it is safe |
| --- | --- |
| `terraform plan` output, as a job summary or a PR comment | It is a diff of resource attributes, and the only personal value in this config is `budget_email`, now `sensitive` |
| `GET /status` — ingest freshness from `system.view_refreshes` and the newest snapshot id | Operational state with nothing secret in it, and the thing a reader actually wants: is the data current. Measured at 55 ms, behind the CDN |
| `GET /coverage` — per-day data health from `ingest_day_health`: `day`, `snapshots`, `vehicle_locations`, `duplicate_ids`, `rides`, `rides_with_duration`, `rides_linked_to_gtfs`, `measured_at`, newest day first, `?limit=` defaulting to 90 and capped at 10,000 | Public for the same reason, and it answers the question production cannot. Finding 13 is twenty months of "zero buses ran" that reads as data rather than as an outage, because `/gtfs_rides_agg/group_by` returns 0 either way. Here a day says how many snapshots arrived, how many rows were derived from them, and whether its ids are sound — so "nothing ran", "nothing arrived" and "we broke it" are three different rows and not one |
| `infra/rates.json` and `scripts/measure-cost.py` | Public rates and a script. An estimate nobody can re-derive is one nobody should act on |

**The state bucket stays private, and the honest reason is not secrets.** This configuration
creates nothing that generates a credential — no database password, no access key, no
certificate — so there is no secret in the state file today. What is in it is the account id,
resource ids, and an email address that is published deliberately. Saying "a credential might
end up there" is true of any Terraform project and is not a reason on its own.

The reasons that do hold are both about the bucket rather than the file:

- **A public-read bucket is a cost amplifier.** S3 GET requests and transfer out are billed to
  the bucket's owner, so anyone who wants to can loop on the object and put it on your bill.
  For a project whose whole case is a $150 ceiling, that is not theoretical.
- **A public-write bucket would be worse than a leak.** Anyone could rewrite the state, and the
  next `terraform apply` would destroy or recreate real infrastructure to match it.

And there is a better way to get what a public state file would give. The `deploy` workflow
writes `terraform show` of the plan into the job summary, which is public because the
repository is, and which is the readable part anyway. Worth knowing for the day this
configuration does grow a credential: `sensitive = true` redacts a value in `terraform show`
and **not** in the file. Measured — a variable marked sensitive, printed as `(sensitive value)`,
appears verbatim in `terraform.tfstate`.

AWS blocks public access on new buckets by default. Leave that on.

**CloudWatch, and why there is none.** Nothing here ships logs anywhere: ClickHouse writes to
`/var/log/clickhouse-server/`, the two cron jobs to `/var/log/stride-*.log`, and the API to the
journal. That is not an oversight to be fixed by turning CloudWatch on, for two reasons. It
costs $0.50 per GB ingested and $0.03 per GB stored, which is a new line on a bill this
project is arguing down. And a CloudWatch log group **cannot be made public** — there is no
public-read mode for one, so shipping logs there would move operational state further from the
public, not closer.

What raw logs would also carry is the thing to be careful about: ClickHouse's `system.query_log`
records the query and the client address, so publishing it verbatim publishes visitors' IP
addresses. The open version of this is derived state and not raw logs — `system.view_refreshes`
and the newest ingested snapshot id, measured at 78 ms for the whole set, which says what a
reader actually wants to know (is the data current) and contains nothing about anyone.

### Resizing the disk

**Up, online, any time. Down, never.** `aws ec2 modify-volume` grows a gp3 volume with no
downtime and no detach; the filesystem then needs `resize2fs` to see it. There is a cooldown of
about six hours before the same volume can be modified again.

Shrinking is not a modification at all: it means a new smaller volume, a copy, and a swap. That
matters more in Terraform than on the command line, because **lowering `data_volume_gb` plans a
replacement**, and replacing this volume destroys the database and the fifteen hours of
backfill that filled it. `aws_ebs_volume.data` therefore carries `prevent_destroy = true`, so
that mistake is an error instead of a silent loss. For a deliberate teardown, remove the block,
apply, then destroy.

**Also private, and for a different reason:** the actual bill, and Kamatera's invoice. Those
are the organisation's spend, not ours to publish. Estimates derived from published rates are
a different thing and belong in the open, which is why this document is full of them.

**What is deliberately not here:** no RDS, no managed ClickHouse, no Kubernetes, no message
queue, no Redis, no Airflow. The scheduler is `REFRESH EVERY` inside the database and the
monitoring is `system.view_refreshes`.

---

### Would scaling out ever pay?

Asked out of curiosity, answered with measurements, and the answer is no for a long time —
but not for the reason one would guess. Everything below was measured on the single node while
the backfill was running, so it is a loaded box rather than a quiet one.

**Read concurrency is not the constraint, by four orders of magnitude.** The query the map
actually issues — a 30-second window of vehicle locations, 1,000 rows — with every request
asking for a different window so nothing is served from a cache:

| Concurrent requests | Wall | p95 | Throughput |
| --- | --- | --- | --- |
| 1 | 185 ms | 171 ms | 5.4 req/s |
| 4 | 231 ms | 218 ms | 17.3 req/s |
| 8 | 212 ms | 196 ms | 37.7 req/s |
| 16 | 227 ms | 214 ms | 70.5 req/s |
| 32 | 227 ms | 200 ms | **141 req/s** |

p95 is flat from 1 to 32. Against that, the real traffic is 39,123 page views a month — about
**0.015 requests a second** averaged, and a hundredfold peak is still 1.5. One node is not
close to its limit, and CloudFront sits in front of it absorbing the repeats anyway.

**Latency is the constraint, and it is not the kind more machines fix.** Per endpoint, locally:

| Endpoint | |
| --- | --- |
| `/stop_arrivals/list` | 0.02 s |
| `/gtfs_ride_stops/list` | 0.05 s |
| `/gtfs_rides_agg/group_by`, 20 days | 0.14 s |
| `/siri_velocity_aggregation`, 2 h box | 0.69 s |
| `/siri_rides/list`, 5 min | 1.20 s |
| `/rides_execution/list`, one day one line | 3.96 s |
| `/route_timetable/list`, 30 min one line | **6.53 s** |

The slow one walks `gtfs_ride_stop`, which is 4.68 billion rows, and that is exactly the shape
sharding is supposed to help: split the rows, split the scan. Except it would not, because the
query does not scale with threads either:

| `max_threads` | |
| --- | --- |
| 1 | 6.19 s |
| 2 | 7.10 s |
| 6 | 7.10 s |

Six cores are no better than one, so six nodes would be no better than one. The `by_ride`
projection is materialised across all 18 parts (62.37 GiB), and driving the joins from the
route side instead of the stop side changes nothing — 6.19 s either way. **The cause is not
found**, and it is in [the roadmap](../ROADMAP.md) rather than guessed at here. What is
established is that it is not a capacity problem.

**And at the next step up, out and up cost the same.** A two-shard cluster is two instances,
the same total disk split between them, and two addresses: $133.42 a month. A single
`t4g.xlarge` with twice the cores and twice the memory is $129.76. The same money, and it needs
no distributed tables, no cluster configuration and no replication to operate.

This paragraph used to add "and it lifts the 4 GiB ceiling that an unfiltered
`/siri_rides/list` hits". That measurement was taken against a 4 GiB cap, and the local cap is
now 8 GiB (`ingest/local.xml`), chosen to match the `t4g.large` this module actually deploys —
so the old figure measured a box stricter than the target and says nothing about this one.
**Whether 8 GiB is enough for that call is not measured.** Re-measuring it means running an
unfiltered three-way join on the shared database that the ingest and enrichment chains are
writing to, and a `MEMORY_LIMIT_EXCEEDED` there is not confined to the query that caused it.
It is worth doing on a throwaway instance and it has not been done.

So the order is: fix the query, then buy a bigger box, and only then think about a second one.
The cases where a second one is actually the answer are:

- **Data outgrowing one volume.** gp3 stops at 16 TiB and the database is 280 GiB growing at
  36 GiB a year. That is centuries, not years.
- **Availability.** Explicitly not a requirement here — the requesters keep writing to S3 and
  everything else is derived, so days of downtime cost nothing but freshness.
- **Read concurrency.** Four orders of magnitude away, and CloudFront is the cheap version of
  it: the frontend's query strings repeat under a 300 s TTL, and 39,123 views a month sits far
  inside the permanent 1 TB and 10 M request free tier.

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
  and GTFS loads a day in 35 s through `ingest/gtfs.sh`.
- **The local database is not a complete history, so it is not yet the thing to copy.**
  Measured 2026-11-07: September and October 2026 were never loaded, most of November is
  missing, 2026-08-19 and 2026-08-20 are short at the download (455 and 1,318 snapshots against
  about 1,430), and twenty-five days carry duplicate ids. `scripts/first-load.sh` is written
  against a sound source and does not check whether the backup it restores is one —
  `GET /coverage` and `ingest/verify.sql` are what answer that, and they have to be clean
  before the `publish` stage is allowed to define what every later instance holds.
- **The first load has not been run on AWS.** Every mechanism in it is tested — the streaming
  dump load, the stage machine's skip, retry and refusal, the chain being stopped and restarted
  around a reload, `BACKUP`/`RESTORE` round-tripping a 22-table database with its projections —
  but on a sandbox ClickHouse against a miniature dump, not on an instance against the real
  one. The S3 transport and the STS hop that signs it are unverified.
- **`gtfs_ride_stop` is loaded but not refreshed.** It is a quarter of the database on its own
  and the daily GTFS loader replaces the rest of the GTFS tables, not this one.
- **Nothing has run unattended for 24 hours.** Ingest and enrichment cost 14.7 s per hour of
  feed, so a week of missed data takes about 41 minutes — but RSS and CPU held over a full day
  of continuous running are unmeasured, and that is the number a deployment should be sized on.
- **`/siri_velocity_aggregation` is not reproducible**, in production either — see
  [FINDINGS.md](FINDINGS.md) finding 5.
- **The `siri_ride_stop` projection is predicted, not measured.**

[ROADMAP.md](../ROADMAP.md) tracks all of it.
