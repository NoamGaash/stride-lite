# Roadmap

[עברית](ROADMAP.he.md)

What is left, and what is deliberately left out. How the current state was reached is in
[docs/DESIGN.md](docs/DESIGN.md) and [docs/BENCHMARKS.md](docs/BENCHMARKS.md).

## Acceptance criteria

1. **Every API endpoint preserves its behaviour**, proven by comparison against production.
   Met: 27 of 27 endpoints, 48 differential cases.
2. **A simple implementation.** No complexity beyond what the problem demands. Every
   component justifies its existence.
3. **Modern infrastructure**: test coverage, infrastructure as code, CI/CD in GitHub Actions.

## Next

- **Run under Hasadna's ArgoCD.** ClickHouse alone on a Kamatera server on the internal
  network, and the API, the schema and the jobs as the image this repository publishes. What
  lives where is in [deploy/hasadna/README.md](deploy/hasadna/README.md).
- **Compare a day this build ingested itself.** Every differential case sits in the dump's
  window, 2025-01-01 to 2026-05-29; a second case set on a freshly ingested day is what tests
  the live chain, the SIRI↔GTFS link and the backfilled durations ride by ride.
- **Map the slow requests** ([#36](https://github.com/NoamGaash/stride-lite/issues/36)).
- **Store less** before growing the disk: the column types of `siri_vehicle_location`
  ([#28](https://github.com/NoamGaash/stride-lite/issues/28)), projections that serve one
  endpoint each ([#29](https://github.com/NoamGaash/stride-lite/issues/29)), and the landing
  table `siri_vehicle_location_raw`, which nothing prunes after enrichment.

## Known gaps

- **Twenty-five days of our own data were written twice, and on one of them `id` is not a
  key.** The enrichment mints `id` as `max(id) + row_number()`, so two passes that overlap read
  the same starting max and hand out the same numbers. The hourly refreshable view ran during
  a backfill and doubled 2026-06-15 and every day from 2026-07-26 to 2026-08-23 — up to 5.6M
  duplicate rows a day, and on 2026-06-15 **704,018 ids each cover two different readings**.
  `siri_ride` carries 67,631 duplicate ids, all in August. `ingest/backfill-range.sh` stops the
  chain itself and `ingest/verify.sql` gates every day, so it cannot recur; the affected days
  are still to be repaired.
- **Some days are short at the source.** 2026-08-19 holds 455 of about 1,430 snapshots,
  2026-08-20 holds 1,318, and 2026-11-19 holds 547, a fault on the Ministry's server.
  `/coverage` shows each day's counts. Friday and Saturday are legitimately a half and a sixth
  of a weekday, which is why it reports counts and never thresholds them.
- **`siri_vehicle_location` has no `PARTITION BY`** — one partition of 120 GiB — so no day can
  be dropped cheaply and every repair is a mutation over the whole table. The landing table is
  partitioned by month; the fact table probably should be too.
- **The `siri_ride_stop` projection's speed is predicted, not measured.** The 0.015 s it is
  expected to give is measured on `gtfs_ride_stop`'s.

## Deliberately out of scope

Criterion 2 is a constraint with teeth. Each of these was considered and dropped:

- **dbt.** In the existing repo it templates SQL and passes date parameters for backfills.
  That requires a Python toolchain with `uv` and a `profiles.yml` to get Jinja templating
  over five models. The simpler substitute: a short `scripts/migrate.sh` for migrations,
  refreshable materialized views for the steady state, and one parameterised SQL file for
  backfill invoked through `clickhouse-client --param_`.
- **A scheduler, a message queue, a cache layer.** ClickHouse schedules; a CDN caches. Any
  additional layer has to justify itself with a measurement.
- **An ORM.** 27 GET endpoints with filtering and sorting are query construction, not an
  object model.
- **Rewriting the SIRI collector.** It works and it is the source of the data. Rewriting it
  is risk without return.

## If this goes anywhere

The code splits back into the org's repositories — `db/` and ingest into
`open-bus-stride-clickhouse`, `api/` into `open-bus-stride-api`. The directory boundaries are
kept clean so that split is mechanical rather than a rewrite.

## On cost

What it costs to run is in [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md), from AWS's own price list.
The comparison with the current infrastructure is in [docs/BENCHMARKS.md](docs/BENCHMARKS.md),
derived from published AWS and Kamatera rates applied to the specs in the public `hasadna-iac`
Terraform, so it is reproducible from public information.

**What the project actually pays is not here.** That figure was reported privately and belongs
to the project's maintainers to publish or not. Where the analysis needs it — the share of the
bill that goes to ETL workers rather than to the database — the ratios are computed from the
public specs, which gives the same conclusion without the invoice.
