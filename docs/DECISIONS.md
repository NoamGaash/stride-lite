# Who decided what

[עברית](DECISIONS.he.md)

This repository is one person's brief and an AI agent's execution of it. Those are not the
same thing, and a reader deciding whether to trust a number here needs to know which is
which. Three lists follow: what was asked for, what the agent chose on its own, and what it
actually did.

## What [@NoamGaash](https://github.com/NoamGaash) asked for

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
| **All of the history on the machine.** Not a recent window | Tiered or partial storage as the default, and with it most of the storage saving |
| **90% availability is enough, and less at night; losing data at the source is not.** Downtime of the API is fine because everything it serves is derived, but a SIRI snapshot nobody stored cannot be asked for again (2026-11-20) | Failover and standby nodes for the API. Not a second requester, nor alarms that reboot a hung node — see [docs/REQUESTER.md](REQUESTER.md) |
| **A second SIRI requester of our own, every 15 seconds, as simple as a `curl`** (2026-11-20, after Hasadna's requester lost 18 hours on 18–19 November) | Asking once a minute as Hasadna does, and running Hasadna's own Python daemon pinned to 2021 dependencies — [#63](https://github.com/NoamGaash/stride-lite/pull/63) |
| **Keep the Ministry's GTFS in both its current and its new 10-day format** (2026-11-20) | Archiving only the format the ingest reads today — [#66](https://github.com/NoamGaash/stride-lite/pull/66) |
| **Shrink the instance before touching storage**, and decide each step on measured peaks (2026-11-20) | HDD or S3 tiers as the next saving while the instance is still oversized — [#67](https://github.com/NoamGaash/stride-lite/issues/67) |
| **The experimental API is the frontend's default**, to put real load on it, measured in Google Analytics (2026-11-17) | Keeping it opt-in until it is "ready" |
| **Lock files are committed**, the dev container's included (2026-11-21) | Floating feature and dependency tags |
| **Only the newest commit waits for deploy approval** (2026-11-21) | A run waiting for review holding the queue, so the next approval deploys an older commit |
| **A week's trial of a t4g.small's memory on the t4g.medium, before shrinking again**: ClickHouse capped at 1.5 GiB, a 2 GiB swap file for heavy nights (2026-11-23) | Shrinking first and finding out from an OOM kill; the two sizes have the same CPU, so memory is the only question |
| **Every version of the 10-day GTFS is archived**, not only the first of each day (2026-11-22) | A same-day update by the Ministry lost |
| **Run under Hasadna's ArgoCD like the old project** (2026-11-24): ClickHouse alone on a Kamatera server on the internal network, and the API, migrations and ingest as images in `apps/openbus`. Asked by Hasadna's infrastructure maintainer, who would not run a server that pulls code from GitHub itself. Meanwhile the AWS node keeps deploying from main as today, until switched off by hand | A server outside ArgoCD that nobody but its author can operate |
| **Everything particular to one environment under `deploy/<environment>/`** (2026-11-24): `aws`, `hasadna`, `local`, the code reading only environment variables, so a fork in Hasadna's organisation that sets its own runs end to end | AWS and Hasadna specifics woven through `scripts/` |
| **Hasadna's SIRI requester stays the only one** (2026-11-24); features we want go to it as pull requests | A second requester behind the same allowlisted proxy, which together with Hasadna's would ask more often than the ICD allows |
| **Tel Aviv's weekend lines, "Naim BaSofash", are archived too**: the city's GTFS and its GTFS-RT every 10 s (2026-11-23, [#74](https://github.com/NoamGaash/stride-lite/issues/74)) | A weekend nobody copies is gone; whether the Ministry's feeds carry these lines is unverified |
| **Deletion is not irreversible** where the output is reproducible with compute | Treating 208 GB of intermediate files as precious |
| What the project pays today is **private**; estimates from public rates are fine | Any comparison quoting the real invoice |
| **Where production has a bug, fixing it justifies departing from byte-for-byte** | Inheriting a defect to make a comparison pass — see finding 13 in [docs/FINDINGS.md](FINDINGS.md) |
| **Install whatever is needed to run things.** The session is in a container | Verifying by reading source what could have been executed |
| **A test for a fix must be shown failing without the fix** | A test committed on the strength of passing once |
| **Open by default, in the Workshop's spirit.** Publish anything that does not expose a third party; the owner's own email, the S3 GET bill and his own AWS bill are his to spend (the bill on the status page: [#64](https://github.com/NoamGaash/stride-lite/issues/64)) | Redacting the budget address, and the argument that a public bucket is unsafe because of its cost |
| **Cheapest wins, some performance loss is acceptable** | eu-west-1 for same-region reads, and m7g over a burstable instance |
| **Data quality in the ministry's feed is a public finding, not an embarrassment to hide** | Quietly working around the 2038 timestamps instead of writing them up — see finding 14 |
| A **public repository**, no secrets, Hebrew and English documentation | — |
| **One image for the API, the schema and the jobs, in every environment**, on Node 26 (2026-11-24) | Shell scripts on the node installing a runtime |
| **A deploy reaches AWS only through the deploy workflow, after approval**; nothing on the node polls for commits (2026-11-25) | A timer that deploys a merge before anyone approved it |
| **No dead code and nothing that runs without a purpose. The documentation describes the current state; decisions live here, not in the README** (2026-11-25) | History notes in the docs, and a job that runs only to skip |
| **AI agents must identify themselves** when acting in the project (the repo's own rule) | — |

## What the agent interpreted, chose, or assumed

None of the following was requested. Each is a judgement call, and each could be wrong.

| Decision | Why | What would overturn it |
| --- | --- | --- |
| **ClickHouse**, single node | The workload is append-only analytics over one wide fact table | A write pattern needing real transactions |
| **"Same results" read as byte-identical JSON**, not matching status codes | A weaker reading makes criterion 1 untestable | — |
| **TypeScript** for the API | The generated client and the frontend are already TypeScript | — |
| **Refreshable materialized views as the scheduler** | `system.view_refreshes` already reports what Airflow is deployed to report | Work that genuinely needs a DAG, not a cadence |
| **No dbt, scheduler, queue, cache or ORM** | Criterion 2 — each would have to earn its place | A measurement showing one is needed |
| **Terraform**, as a module beside `hasadna-iac`'s existing ones | Continuation rather than a parallel toolchain | — |
| **The stale dump's window is the test boundary** | Every differential case must sit inside it or fail for a reason that is not a bug | Fresh data — which continuous ingest now provides, so the newer cases compare against today |
| **Sequential surrogate ids**, taken from the dump and continued with `max(id) + row_number()` | It is what the dump holds, so historical responses compare byte for byte | Measured 2026-11-05: identity derived as a hash of the natural key answers the same query ~100x faster and would delete the 52% of the database that exists only to hold these keys. The id constraint permits a wider type, so nothing blocks it but the work — see [db-benchmark](https://github.com/NoamGaash/open-bus-map-search/tree/main/db-benchmark) |
| **Precomputation only where a query cannot do the work** | `gtfs_rides_agg_by_hour` as a plain view exceeds a 4 GiB ceiling, and stored it costs 181 MiB — 0.07% of the database. The identity tables cost 52% and make queries slower | — |
| **`t4g.medium` + 350 GB gp3 in us-east-1** | Ten hours of `/ops/metrics` history on the `t4g.large` showed 1.5 GB in use at p95 and 17% CPU demand on average; on the `t4g.medium` ClickHouse peaked at 2.65 GB in its first nine hours, with no `MEMORY_LIMIT_EXCEEDED` and 1.6 s of memory stall since boot. A query that would need more than the API's 1.5 GiB cap answers "too broad" on any size. The same peak rules out a `t4g.small` (2 GB) | A week of maxima ([#65](https://github.com/NoamGaash/stride-lite/pull/65)) showing the daily GTFS load or a refresh failing |
| **The second requester is a `curl` on a 15-second systemd timer**, not a daemon | A oneshot run killed at 14 s cannot hang, so no watchdog is needed; the key reaches `curl` on stdin, never on a command line; an answer is kept only if its `ResponseTimestamp` is under two minutes old; TLS is verified, where Hasadna's requester turns it off | The Ministry's certificate turning out invalid, which its first real run will show |
| **One public bucket for the Ministry's feeds, `openbus-mot-archive`**, with SIRI at `siri/YYYY/MM/DD/HH/MM/SS.br` and GTFS at `gtfs/YYYY/MM/DD/` (the 10-day format one level deeper, at `HHMMSS/`), and Tel Aviv's weekend lines under `naim/` | Hasadna's per-minute layout has no room for seconds; GTFS is dated by the Ministry's own `Last-Modified`, so a version is fetched once. The current format keeps Hasadna's one-a-day layout so their readers can read ours; nothing reads the 10-day format yet, so it keeps every version | Joining Hasadna's archive instead, if the AWS Open Data application leads there ([#68](https://github.com/NoamGaash/stride-lite/issues/68)) |
| **Alarms that reboot or recover the node, rather than a standby that takes over its address** | Moving the Elastic IP to a standby needs a Lambda, two instances and states that cannot be tested on demand; a reboot keeps the same instance, address and volume, and the requester inside is guarded by `OOMScoreAdjust=-1000` and `CPUWeight=1000` | A host failure that recover does not fix |
| **A fresh instance loads the whole history by itself**, as a `oneshot` unit rather than a command somebody remembers to run | A deploy that leaves an empty database is a deploy that does not work, and "run this afterwards" is a step that gets skipped. Five resumable stages, state on the data volume: [docs/DEPLOYMENT.md](DEPLOYMENT.md) §"What the first deploy leaves you with" | — |
| **A restorable copy of the database in our own S3, at $5.86 a month**, preferred over rebuilding from public data | Reading `s3://openbus-stride-public` is billed to Hasadna, so "download once, ever" has to be a property of the design and not a habit. First instance rebuilds and publishes; every later one restores, in 35 minutes and for nothing | A cheaper storage class, or a project that would rather spend days of compute than $70 a year |
| **us-east-1 stays, re-priced against the bulk load** | eu-west-1 would spend $120.72 a year of ours to save $3.75 of Hasadna's once and $1.32 a year after. Measured both ways from AWS's own price list on 2026-11-07 | A measurement of latency from Israel, which has never been taken |
| **`deploy/hasadna/` holds a README, not copies** | The chart and the server definition live in hasadna-k8s and hasadna-iac, where Hasadna reviews them; a copy here would drift | — |
| **`api_domain` optional and off by default**, with the CloudFront name as the frontend's address | A name in `hasadna.org.il` needs a record in a Cloudflare zone this repository does not own, so it cannot be a precondition for deploying; the frontend's CSP allows `*.cloudfront.net` | — |
| **A deploy names its commit**: the one whose image CI has just published | main may already be at a commit whose image does not exist yet, and nothing retries a failed deploy | — |
| **The SIRI requester's timer is enabled only once the key is in `node.env`** | Without the Ministry's key every run would be skipped, four times a minute | — |
| **A deploy removes the node's units that the repository no longer has** | A unit deleted from `deploy/aws/node` would otherwise keep running on the node | — |

## What the agent actually did

Measured, in a session, and reproducible by [docs/LOCAL-DB.md](LOCAL-DB.md):

- Loaded the full 13,728,053,041-row public dump and measured storage per table and per engine.
- Wrote the API: **all 27 endpoints, verified byte-identical** across 48 differential tests.
- Built the continuous SIRI ingest from S3 — three SQL objects, no scheduler.
- Wrote the CI, the Terraform module, and 35 unit tests on SQL generation.
- Capped its own work on the machine: 6 of 24 cores, `nice 19`, and ClickHouse's own
  bandwidth and memory ceilings.

- Built the enrichment, so SIRI flows from S3 to the API with no scheduler.
- Found that neither production nor this implementation compressed anything, and fixed it
  upstream: `/siri_vehicle_locations/list` serves 362,974 bytes where gzip gives 33,503, and
  `/openapi.json` 130,022 where gzip gives 9,186. Opened
  [hasadna/open-bus-stride-api#69](https://github.com/hasadna/open-bus-stride-api/pull/69)
  with three tests, each shown failing without the fix.
- Checked the CloudFront free tier against real traffic: 39,123 page views in 30 days leave
  256 requests and 27 MB of free allowance per view, so egress is projected to cost nothing at
  this scale. The binding limit is requests, not bytes.
- Closed port 22. The instance profile already carries SSM and no key pair is attached, so the
  SSH rule admitted nobody.
- Read the upstream ETL rather than guessing at it, which is what settled the ride-identity
  and coordinate-dropping rules, and what turned up the findings in
  [docs/FINDINGS.md](FINDINGS.md).
- Wrote the first load, so a deployed node holds the whole history rather than whatever
  arrived after it booted: `scripts/first-load.sh`, five resumable stages, started as a
  systemd unit by `deploy/aws/bootstrap.sh`.
- Measured the whole public SIRI archive without downloading any of it — 288,970,717,345
  bytes in 2,794,246 objects, by unsigned `LIST` — and priced all three ways to fill a node
  from AWS's own price list, in both regions, for both payers.
- Found two things in the load path that would have failed on the first real run, by
  reproducing both: `load-from-dump.sh` deadlocked forever on any table the dump has no
  `COPY` block for, which is every table this project added; and `MATERIALIZE PROJECTION`
  rewrites every part even when the projection is already complete, so every deploy rebuilt
  74 GiB of projections.

- Found where the 18-hour gap of 18–19 November 2026 came from, and where it did not: the
  Ministry's files are missing from Hasadna's archive itself (1,214 and 547 of ~1,430), and
  production is empty for the same hours, so neither ingest lost them. The Ministry's own ICD
  (SM 2.8, §7.15 and §7.18) builds a new answer every 15 seconds and allows a request that
  often, which is why the second requester asks four times a minute. The cause itself, as
  the user learned on 2026-11-23: a fault on the Ministry's server, not in Hasadna's requester.
- Resized the node from `t4g.large` to `t4g.medium` on measured memory, and added a week of
  per-minute load and memory history to `/ops/metrics`, as average, p95 and maximum.
- Traced 141,147 `NOT_IMPLEMENTED` errors in `system.errors` to ClickHouse's speculative set
  build for a nested `IN`, which it catches and falls back from at the same speed; reproduced
  on 26.10 with and without nesting. Harmless, and no performance to gain.
- Measured the inputs of an AWS Open Data application on 2026-11-21: Hasadna's SIRI archive
  is 289 GB in 2.79 million files from April 2021, its GTFS archive 272 GB in 6,820 files from
  January 2022.
