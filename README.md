# stride-lite

[עברית](README.he.md) · [How it works](docs/DESIGN.md) · **[What this found out about production](docs/FINDINGS.md)** · [Cost and deployment](docs/DEPLOYMENT.md) · [Roadmap](ROADMAP.md) · [Measurements](docs/BENCHMARKS.md) · [Run it locally](docs/LOCAL-DB.md) · [A second SIRI requester](docs/REQUESTER.md) · [Who decided what](docs/DECISIONS.md)

A from-scratch reimplementation of the [Open Bus Stride](https://github.com/hasadna/open-bus-stride-api)
backend on ClickHouse. Same API contract, byte for byte; a fraction of the storage; no
Airflow.

This is an experiment, not a proposal to merge. It exists to answer one question with
numbers instead of opinions: **what would the Israeli public-transport data backend cost and
look like if it were built today?**

> 🤖 Most of the work in this repository was done by Claude (an AI agent) working with
> [@NoamGaash](https://github.com/NoamGaash). What was asked for, what the agent chose and
> what it did are kept apart in [docs/DECISIONS.md](docs/DECISIONS.md). Every number is
> measured and reproducible by [docs/LOCAL-DB.md](docs/LOCAL-DB.md).

## Quickstart

```bash
./up.sh
```

That is the whole thing. It fetches the ClickHouse binary, starts it under a memory ceiling,
I/O limits and six cores, creates the 16 tables, installs the ingest and enrichment chains,
backfills two hours of live SIRI from S3, and starts the API on :8080. From that moment the
database keeps itself current with no scheduler and no worker. `./up.sh 6` backfills six
hours instead; `./up.sh 0` backfills nothing and only moves forward.

`/docs` is the API's Swagger UI, and `/openapi.json` its spec: production's own, with each
filter marked `x-lookup: indexed` or `scan`. The mark is read from `db/schema.sql` and
`db/projections.sql`, so it says what the database can actually find without a full read.

No Docker, no root, no credentials — the data is public. The resource ceilings are in
[`deploy/local/local.xml`](deploy/local/local.xml) and exist because the reference machine for
this project is somebody's workstation; on a dedicated host, raise them. The full reproduction,
including the 13.7-billion-row dump, is in [docs/LOCAL-DB.md](docs/LOCAL-DB.md).

## Contributing

Open the repository in its dev container (`.devcontainer/`). It brings Node, Hurl, Terraform,
the AWS CLI and the ClickHouse binary at CI's versions, and starts nothing until you run
`./up.sh`.

Every test runs in CI, [`.github/workflows/ci.yml`](.github/workflows/ci.yml), and each step's
name says what it proves; run the same command locally. A test for a fix is shown failing
without the fix before it is committed.

## Where it stands

**27 of 27 endpoints return the same JSON as production**, ids included, because inside the
comparison window both databases hold the same rows under the same ids. Checked on 2026-11-25
against the AWS deployment with [`scripts/check-production.sh`](scripts/check-production.sh):
54 of 54 cases passed (48 differential, 5 on ride durations, 1 on coverage), the newest SIRI
snapshot was minutes old, and no refresh had failed.

| | |
| --- | --- |
| Endpoints matching production | **27 of 27** |
| Differential tests | 48, covering every endpoint in the published spec |
| Fields excluded from comparison | 2, both with a measured reason |
| Unit tests | 188, no database required |
| Lines of API code | 2,790 TypeScript |

A coverage test fails if the published spec ever grows an endpoint the suite does not exercise,
so "27 of 27" cannot quietly become 27 of 28.

**Three things that number does not claim:**

- **`/gtfs_rides_agg/list` has no production baseline.** Production answers it with a statement
  timeout — measured at 86 s and again at 103 s on a single day — so the case asserts only that
  this implementation answers. The data behind it is verified through
  `/gtfs_rides_agg/group_by`, which reads the same aggregate and does answer.
- **Two fields of `/siri_velocity_aggregation` are excluded.** Its rolling average uses a `ROWS`
  window over an `ORDER BY` with ties, so the frame depends on physical row order. Three
  identical calls to this implementation returned three different values, which means production
  cannot be stable either.
- **`/stop_arrivals/list` matches by both sides returning nothing.** That is the only contract it
  can still be held to, and why is in [FINDINGS.md](docs/FINDINGS.md).

## Open work

- **The differential suite compares only the window both databases hold from the public dump**,
  2025-01-01 to 2026-05-29: production keeps nothing older, and the dump ends there. A day this
  build ingested itself is not compared yet; a second case set on such a day is what closes it.
- **The SIRI↔GTFS link and the backfilled ride durations are not yet compared with production
  ride by ride.** [`ingest/gtfs-link.sql`](ingest/gtfs-link.sql) ports upstream's
  `siri/update_rides_gtfs.py`, and [`ingest/duration-history.sql`](ingest/duration-history.sql)
  fills the durations production stopped measuring in November 2024
  ([open-bus-stride-etl#22](https://github.com/hasadna/open-bus-stride-etl/issues/22)). On a
  recent day the link rates match production's (71% by journey, 98.5% by route, against 73% and
  98%), which is agreement, not proof.
- **Which requests are slow, and why, is not yet mapped**
  ([#36](https://github.com/NoamGaash/stride-lite/issues/36)). `/route_timetable/list` is the
  clearest case: two uncached requests on the AWS node on 2026-11-25 took 6.5 s and 1.3 s.
- **The disk is 88% full: 46 of 369 GB free** on the AWS node on 2026-11-25. The plan is to
  store less rather than grow the volume: the column types of `siri_vehicle_location`
  ([#28](https://github.com/NoamGaash/stride-lite/issues/28)), projections that serve one
  endpoint each ([#29](https://github.com/NoamGaash/stride-lite/issues/29)), and the landing
  table `siri_vehicle_location_raw`, which nothing prunes after enrichment.

More in [ROADMAP.md](ROADMAP.md).

## Layout

```
up.sh             one command: binary, server, schema, ingest, enrichment, API
Dockerfile        the one image: the API, the schema and the jobs
api/              TypeScript service and its tests
db/               schema.sql (the 16 tables), views.sql, projections.sql, migrations/
ingest/           siri.sql (ingest), enrich.sql (6-step chain), gtfs-link.sql (SIRI → GTFS),
                  duration-history.sql (past durations), catchup.sh, gtfs.sh, backfill.sh
scripts/          tools that run anywhere: apply-schema.sh, migrate.sh, first-load.sh,
                  backup.sh, gtfs-archive.sh, naim-rt-request.sh, check-production.sh, ...
tests/            tests of the above
deploy/aws/       the AWS node: Terraform, systemd units, cron, bootstrap, deploy.sh, its tests
deploy/hasadna/   README only: what lives in hasadna-iac and hasadna-k8s
deploy/local/     ClickHouse settings for a workstation, used by up.sh
docs/             design, decisions, findings, measurements, deployment, local setup
```

Everything particular to one environment is under `deploy/<environment>/` and reaches the rest
as an environment variable (`CH_URL`, `API_URL`, `ARCHIVE_BUCKET`, ...); `tests/boundary.sh`
fails CI if an account id, a domain or a host path appears outside it. So a fork that sets its
own values runs end to end, and retiring an environment is deleting its directory.

## Honest caveats

- **GTFS needs cron, SIRI does not.** ClickHouse reads S3 by itself but cannot read a
  multi-file zip, so the GTFS feed is fetched by a shell script once a day. It is the only
  scheduled job outside the database.
- **61 rows in a measured minute still differ** from production in
  `siri_ride__scheduled_start_time`, for one vehicle with a sentinel journey ref, and the
  cause is not understood.
- **PostgreSQL wins one query** — a selective `line_ref` + bounding-box filter, 0.017 s
  against 0.063–0.090 s. B-tree indexes on `lon`/`lat` are the right tool there, and closing
  the gap with skip indexes is work not yet done.
- **The AWS estimate's one unquantified input is traffic volume.** Every rate comes from AWS's
  own price list, regenerated by `deploy/aws/bin/fetch-rates.sh` into
  [deploy/aws/rates.json](deploy/aws/rates.json), and compute and disk are 96% of the bill.
  Egress above CloudFront's free 1 TB needs a real traffic figure, and the invoice reads $0
  for egress under the free tier, which is why `deploy/aws/bin/measure-cost.py` exists. What
  the project pays today was reported privately and is not in this repository.
- **Projections are 30% of the footprint, measured.** Four of them take the total from
  163.98 GiB to **233.02 GiB**: `gtfs_ride_stop.by_ride` 29.88 GiB, `siri_ride_stop.by_gtfs_stop`
  19.33 GiB, `siri_ride_stop.by_siri_ride` 18.95 GiB and `siri_ride.by_natural_key` 0.87 GiB.
  `siri_ride_stop` needs two because it is filtered by a different foreign key on each of two
  endpoints and sorted by neither. One of the four, `by_gtfs_stop`, is droppable: it serves
  only `/stop_arrivals/list`, which cannot return a row from production at all.
- This repository does not answer the questions that actually decide a migration: who
  maintains it, what happens at 3 a.m., and what breaks in a provider move. Those are the
  maintainers' calls, and measurements do not settle them.

## Licence

MIT. The data is public, published by the Israeli Ministry of Transport and collected by the
[Public Knowledge Workshop](https://www.hasadna.org.il/).
