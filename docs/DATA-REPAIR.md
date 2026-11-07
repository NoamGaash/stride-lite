# The days we damaged, and what it costs to put them back

We corrupted twenty-nine days of our own database, did not notice for three weeks, and the gate
we then built could not see the worst of it. This is the inventory, the repair, and the arithmetic
on whether to mirror the archive so a repeat costs Hasadna nothing.

Every number here was measured against the database on 2026-11-07, and the queries are in
`ingest/verify.sql` and `ingest/repair.sql`.

## What went wrong

The enrichment mints `id` as `max(id) + row_number()`. That is only a key if one pass runs at a
time. Two overlapping passes corrupt it in **two different ways**, and the difference matters
because a gate that catches one is blind to the other.

**Mode 1 — the same starting max.** Both passes read the same `max(id)` and mint the same
numbers, so one id ends up covering two different readings. `count() != uniqExact(id)` finds it.

**Mode 2 — different starting maxima.** One pass gets its read in after the other has committed
rows, so each mints its *own* id for the same source row. Every id is then unique and every
id-based check passes. This is the one that got through: after an id-only repair, 2026-08-16 held

```
rows              15,189,121
distinct ids      15,189,121
distinct readings  7,294,846    <- (siri_snapshot_id, siri_ride_stop_id, recorded_at_time)
```

— every reading twice, a ratio of 2.08, and `duplicate_ids` reporting 0.

**Mode 2's cause is one table upstream of where it shows.** It is not the fact table racing; it
is `siri_ride_stop`. Measured, 1,287,638 of 2026-08-16's ride stops existed **twice under the
same `(siri_ride_id, siri_stop_id, order)`**, so every landing reading joined to both copies and
produced two locations with two ids. Repairing the fact table alone could never fix that, which
is why `repair.sql` now deletes a ride stop whose natural key is duplicated and not only one
whose id is.

It is worth being precise about which pass is the second one, because the obvious suspect is
innocent. **The refreshable chain does not race itself.** Measured, with a refreshable view whose
body takes about 2 s and whose interval is 1 s: 17 refreshes ran, strictly one after another,
and produced 0 duplicate ids over 8,500 rows. A view with two `DEPENDS ON` parents, which was
the next suspicion because the two live-damaged tables are exactly the two with two parents,
also produced 0 duplicates over 26 refreshes and 1.3M rows. ClickHouse serialises a refreshable
view against itself.

So the second pass is always one we started ourselves beside the chain — `enrich-once.sql` or a
backfill run with the views left on. That is why the fix is a guard on *that* path and not a
change to the chain.

## The inventory

| Table | Duplicate ids | Id band | Days affected |
| --- | --- | --- | --- |
| `siri_ride_stop` | **9,161,623** | 3,669,159,741 – 3,733,952,581 | rides dated 2026-07-27 – 08-22, and 11-06 – 11-07 |
| `siri_ride` | 67,634 | 145,528,913 – 146,039,872 | 2026-08-15 – 08-22 |
| `siri_vehicle_location` | millions of rows a day | 8,340,403,262 – 8,519,881,257 | 2026-06-15; 2026-07-26 – 08-23; 2026-11-06 |
| `siri_route`, `siri_stop`, `siri_snapshot` | 0 | — | none |

And the natural keys, which nothing had checked at all:

| Table | Natural key | Duplicates |
| --- | --- | --- |
| `siri_ride_stop` | `(siri_ride_id, siri_stop_id, order)` | **1,287,638** for 2026-08-16's rides alone; 42,322 for 2026-08-17's |
| `siri_ride` | `(siri_route_id, journey_ref, vehicle_ref)` | 0 above id 140,000,000 |
| `siri_snapshot` | `snapshot_id` | 0 |
| `siri_route` | `(line_ref, operator_ref)` | 0 |
| `siri_stop` | `code` | 0 |

Two things in that table were not known before this session.

**`siri_ride_stop` is the worst-damaged of the three, and the gate could not see it.** The first
`verify.sql` checked `siri_vehicle_location` alone, so 9.16 million duplicate ids sat in the
table the gate did not look at, for three weeks, with every check green. The three dimension
tables are clean for a structural reason and not by luck: they dedup on a natural key before an
id is minted, so a second pass finds the row already there and writes nothing.

**Grouping 3.0 billion rows by id is not the reason it went unchecked.** Unrestricted it takes
3 m 47 s; restricted to the band of ids a pass could have minted it takes **5 s**, because the
table is sorted by `id`. A collision is always between two ids minted above the same starting
max, so a watermark taken before a pass cannot hide one.

### Where the gate can demand zero, and where it cannot

`verify.sql` now checks six things, and the split between exact and approximate is deliberate.

**Exact, threshold zero:** duplicate ids and duplicate natural keys in `siri_ride` and
`siri_ride_stop`. The enrichment dedups on exactly those tuples, so a second row under one is
never legitimate — it can only mean two passes raced. This is where mode 2 is actually caught,
and catching it here is what makes the fact table come out right.

**A ratio, because zero is wrong:** duplicate readings in `siri_vehicle_location`. Duplicate
readings are legitimate there — the comment over `enrich_vehicle_location_src` records 785 of
them on `(siri_snapshot_id, siri_ride_stop_id, recorded_at_time)` in a single measured hour of
production, which is *why* the ingest deliberately does not dedup on that triple. So the gate
cannot demand zero, and the threshold needs defending:

| Day | Ratio | |
| --- | --- | --- |
| 2026-06-16 | 1.0018 | no known damage |
| 2026-08-20 | 1.0023 | repaired |
| 2026-08-23 | 1.0028 | no known damage |
| 2026-11-05 | 1.0031 | no known damage |
| **threshold** | **1.01** | |
| 2026-08-17 | 1.0578 | damaged |
| 2026-08-16 | 2.0822 | damaged |

The clean band is corroborated from a completely independent direction: 785 legitimate duplicates
an hour is 18,840 a day, which on a 7.5M-row day is 1.0025 — the middle of the measured band. So
1.01 sits 3.2x above the highest clean day and 5.8x below the mildest defect, in a gap two orders
of magnitude wide. It is a backstop rather than the primary check, because once the two natural
keys above are unique the doubling cannot happen by construction.

## The unit of repair is the snapshot, not the day

This is the detail that decides the shape of everything else. A snapshot's readings are not
confined to the snapshot's own day. Measured over all 133,763,581 landing rows for 2026/08:

- a reading can be **22.7 hours older** than the snapshot that carried it (872,814 rows are more
  than an hour old);
- **11,855 rows** are dated more than a day *into the future* — the ministry's clock, not ours;
  see finding 14.

So every predicate in `ingest/repair.sql` selects on the snapshot and never on
`recorded_at_time`. The consequence showed up the first time the repair ran: repairing
2026-08-19 alone left its 704 duplicate ids exactly where they were, because all of them were
minted from **2026-08-18's** snapshots carrying readings stamped on the 19th. A repair range has
to be the whole damaged span, which is why `repair-range.sh` reports each day and gates on the
range.

### Should `siri_vehicle_location` be partitioned by month?

**No.** It is 120 GiB in one partition and `PARTITION BY toYYYYMM(recorded_at_time)` was
considered precisely so a damaged day could be dropped cheaply. Four measurements say it would
not help:

1. **It would not contain the damage.** The repair selects by snapshot, and a snapshot's rows
   land in whatever month the ministry's clocks claim — up to 22.7 hours earlier and, for 11,855
   August rows, years later. A month partition does not hold a day's damage, so dropping one
   would not be the repair.
2. **The thing it would speed up is already fast.** Finding every row derived from August's
   snapshots — 209,244,606 of them — takes **2.7 s**, because the existing `id` minmax index and
   the feed's compressibility do the pruning a partition would have done.
3. **It would mint junk partitions.** 0.32% of `recorded_at_time` is in the future, scattered
   over 2027–2038, so the table would acquire about 140 partitions holding a few dozen rows each.
4. **It costs a 120 GiB rewrite** on a machine whose I/O throttle in `ingest/local.xml` exists
   because the first full load pinned the NVMe at 97.6% and made the machine unusable.

The repair uses lightweight deletes instead. `siri_ride` and `siri_ride_stop` carry projections,
which refuse a lightweight delete until the table says what to do about them — so
`db/schema.sql` now sets `lightweight_mutation_projection_mode = 'rebuild'` on both. It is a
MergeTree setting, so a `SETTINGS` clause on the `DELETE`, a session `SET` and a client flag are
each accepted and then ignored; all three were tried. Rebuilding is affordable because the
damage sits at the top of the id space: every row of the damaged band is in 7 parts totalling
940 MiB, out of 61 GiB.

## What a day of the archive costs Hasadna

`s3://openbus-stride-public` is `NOSIGN`, so every byte we read is billed to Hasadna and not to
us. Measured from the bucket listing — two LIST requests a day, about $0.00001 — rather than
estimated:

| Day | Objects | Bytes |
| --- | --- | --- |
| 2026/07/27 | 1,428 | 227,633,001 |
| 2026/09/15 | 1,426 | 238,374,201 |
| 2026/08/19 | **455** | 58,370,142 |

At eu-west-1 list prices, taken from AWS's own price list published 2026-11-04 (`$0.09`/GB
egress for the first 10 TB, `$0.0000004` per GET, `$0.000005` per LIST):

**a full day costs Hasadna $0.022** — $0.0210 of egress and $0.0006 of requests.

Two things follow from the table above.

**2026-08-19 is not our failure.** It holds 455 snapshots because S3 holds 455: the bucket
listing returns `KeyCount 455`. The day is an upstream gap, and anything that reads it as a
failed download is wrong. 2026-08-20's 1,318 is the same kind of fact.

**We have already spent $1.53 of Hasadna's money on this server, and about 60% of it was
waste.** `system.events` reports 15,675,957,319 bytes read from S3, 125,670 GETs and 13,748
LISTs over 222,297 s of uptime: $1.41 + $0.05 + $0.07. The payload actually needed over that
window — 23 days of August and 5 of November — is 6.52 GB, or $0.61. The remaining **$0.92 was
re-reads**, which is the real bill for the incident this document is about.

## Mirroring the archive: not recommended

The proposal is to copy what we need into our own bucket once and read our copy thereafter.
With numbers, for the 162 days from 2026-05-30 to today, about 37.7 GB:

| | Cost to Hasadna | Cost to us |
| --- | --- | --- |
| Copy S3→S3 in eu-west-1 | $0.09 (231,174 GETs, no egress) | $1.16 in PUTs, then **$0.87/month** |
| Copy via our machine | $3.39 of egress | same |
| Finish the archive without a mirror | $1.51, once | $0 |
| Re-derive a day we already hold | **$0.00** | $0 |

**Recommendation: do not build it.** Four reasons, in order of weight.

1. **The landing table already is the mirror, and it is cheaper and better shaped.**
   `siri_vehicle_location_raw` holds 2.80 GiB for 23 days, so the whole archive is about 19.7
   GiB on a disk we already pay for, against 37.7 GB in S3 at $0.87/month. And it is in the form
   the repair actually consumes: `repair.sql` and `enrich-once.sql` read nothing else, with no
   fetch, no credentials and no sync job. This is not a plan — it is what happened today, when
   2026-08-19 was re-derived for $0.00.
2. **It would be insuring a $0.92 loss for $0.87 a month.** That is the measured cost of the
   incident. The premium overtakes the claim in eleven months and then keeps charging.
3. **The live loop is already nearly free.** Measured over 3.1 minutes of steady state:
   **27,872 bytes, 3 GETs, 8 LISTs** — about 13 MB and $0.021 a day, and *dominated by LIST
   requests rather than transfer*, because ClickHouse prunes the glob on `_path` before
   downloading anything. The comment in `ingest/siri.sql` about "60 file headers" a minute
   overstates what actually leaves the bucket by two orders of magnitude. A mirror cannot improve
   a bill that is two cents.
4. **It adds three new ways to be wrong** — a second copy that can go stale, an IAM surface, and
   a sync job — to protect a remainder of $1.51.

What to do instead, in order of value for money:

- **Keep the landing rows.** `DROP_LANDING=0` is already the default in
  `ingest/backfill-range.sh`; this is the whole mirror, and it is already built.
- **Back the data volume up** rather than planning to re-fetch. That is `infra/`, which this
  change does not touch — it is a request, not a commit.
- **Slow `siri_ingest_previous` down** if the live bill is ever worth touching. LIST is about 90%
  of it at 3,840 requests a day; re-listing the previous hour every 30 minutes instead of every
  10 would take $0.019/day to $0.008/day. This is tidiness, not savings.

One caveat on all of the above: AWS publishes a free allowance for data transfer out, and
whether Hasadna's account is inside it is not something this database can answer. If it is, every
egress figure here is an upper bound of zero. The request figures stand either way.

## Running a repair

```bash
./ingest/repair-range.sh 2026-08-01 2026-08-23
```

It runs in three phases — derive every day, then judge every day, then re-measure every day's
health — and the split is not cosmetic. Judging a day before its neighbours are derived fails on
damage that is about to be repaired, because a reading can be 22.7 hours older than the snapshot
that carried it. And the range-wide version of the check held a `uniqExact` state per day, which
over 23 days is 190 million ids at once: it exhausted the 8 GiB server and took the first run
down with it, which is why the gate is now per day.

Phase three matters for a reader rather than for the data: `ingest_day_health` is a
`ReplacingMergeTree(measured_at)` keyed on the day, so without re-measuring, `/coverage` keeps
serving the verdict from before the repair.

It stops the refresh chain and restarts exactly the views that were running, refuses a range
whose landing rows are gone rather than turning damaged data into missing data, deletes what was
derived from the range, and derives it again one day at a time — oldest first, because
`scheduled_start_time` is an `argMin` over the snapshots in the batch. It checks that none of
the SQL it is about to run contains an `s3(` call before it runs any of it, so the no-network
property is enforced rather than promised.

`ingest/enrich-once.sql` and `ingest/repair.sql` both now refuse to start while the chain is
enabled. Measured: with the chain `Scheduled`, the first statement throws and
`clickhouse client` abandons the rest of the file, so the six INSERTs never run. That is the
hole that caused all of this — a person at a terminal, running the enrichment by hand.
