-- Is the fact table self-consistent over a date range?
--
-- The ingest mints `id` as `max(id) + row_number()`, so it is only a key if one
-- enrichment pass runs at a time. Two overlapping passes read the same starting
-- max and mint the same numbers, and this file is the gate that refuses the
-- result. It is a gate and not a diagnostic because the failure it describes
-- actually happened here, to twenty-nine days, and nothing noticed for three
-- weeks.
--
-- The race has TWO failure modes and the first version of this file caught only
-- one of them.
--
--   1. Both passes read the SAME starting max, so one id covers two different
--      rows. `count() != uniqExact(id)` finds it.
--   2. The passes read DIFFERENT maxima, so each mints its own id for the same
--      source row. Every id is then unique and the id checks are structurally
--      blind to it. Measured on 2026-08-16 after an id-only repair: 15,189,121
--      rows, 15,189,121 distinct ids, and 7,294,846 distinct readings — every
--      reading present twice, and the gate calling it clean.
--
-- Mode 2 is caught where it can be caught exactly, which is NOT the fact table.
-- `siri_ride` and `siri_ride_stop` are deduped by the enrichment on a known
-- natural key, so a second row under that key is never legitimate and the
-- threshold is zero. And it is the upstream duplicate that causes the
-- downstream one: 2026-08-16 doubled because its ride stops existed twice under
-- the same (siri_ride_id, siri_stop_id, `order`), so every landing reading
-- joined to both copies and produced two locations.
--
-- In siri_vehicle_location itself zero is the wrong threshold, because
-- duplicate readings are legitimate there — the comment over
-- enrich_vehicle_location_src records 785 of them on
-- (siri_snapshot_id, siri_ride_stop_id, recorded_at_time) in a single measured
-- hour of production, which is why the ingest deliberately does not dedup on
-- that triple. So that one check is a ratio, and MAX_READING_RATIO below says
-- how its value was chosen.
--
-- Row counts per day are reported and never asserted: Friday is about half a
-- weekday and Saturday about a sixth, so a threshold on them would cry wolf
-- once a week. A human reads the column.
--
-- `from_id` is what makes the siri_ride and siri_ride_stop checks affordable.
-- siri_ride_stop is 3.0 billion rows and grouping all of it by id took
-- 3 m 47 s; restricted to the ids one pass could have minted it takes 5 s,
-- because the table is sorted by id. A collision is always between ids minted
-- above the same starting max, so a floor taken before the pass cannot hide
-- one. 0 means "audit everything", which is the right answer once and the wrong
-- one in a loop — and on siri_ride_stop it will not fit in 8 GiB.
--
-- ONE DAY AT A TIME. The day report holds a uniqExact state per group, and over
-- a 23-day range that is 190 million ids at once: measured, it exhausted the
-- 8 GiB server and took the repair down with it. repair-range.sh calls this
-- per day for that reason.
--
-- Usage:
--   clickhouse client -d prod --param_from=2026-08-16 --param_to=2026-08-16 \
--     --param_ride_from_id=0 --param_ride_stop_from_id=0 \
--     --queries-file ingest/verify.sql

SELECT
    toDate(recorded_at_time) AS day,
    dateName('weekday', toDate(recorded_at_time)) AS weekday,
    count() AS rows,
    uniqExact(id) AS distinct_ids,
    count() - uniqExact(id) AS duplicate_rows,
    uniqExact((siri_snapshot_id, siri_ride_stop_id, recorded_at_time)) AS distinct_readings,
    round(count() / uniqExact((siri_snapshot_id, siri_ride_stop_id, recorded_at_time)), 4) AS reading_ratio
FROM siri_vehicle_location
WHERE recorded_at_time >= toDateTime({from:Date})
  AND recorded_at_time < toDateTime({to:Date}) + INTERVAL 1 DAY
GROUP BY day
ORDER BY day;

-- Mode 1 in the fact table. The counts are selected alongside the assertion
-- rather than built into the message, because throwIf takes only a constant
-- there.
SELECT
    sum(extra) AS extra_rows,
    count() AS duplicated_ids,
    throwIf(sum(extra) > 0, 'duplicate ids in siri_vehicle_location') AS ok
FROM (
    SELECT count() - 1 AS extra
    FROM siri_vehicle_location
    WHERE recorded_at_time >= toDateTime({from:Date})
      AND recorded_at_time < toDateTime({to:Date}) + INTERVAL 1 DAY
    GROUP BY id
    HAVING count() > 1
);

-- Mode 2 in the fact table, as a ratio because zero is unreachable here.
--
-- 1.01 was not picked for roundness. Measured over four days with no known
-- damage — 2026-06-16, 08-20, 08-23 and 11-05 — the ratio is 1.0018, 1.0023,
-- 1.0028 and 1.0031. That agrees with upstream's own number from an entirely
-- different direction: 785 legitimate duplicates an hour is 18,840 a day, which
-- on a 7.5M-row day is 1.0025. The two damaged days measure 1.0578 and 2.0822.
-- So 1.01 sits 3.2x above the highest clean day and 5.8x below the mildest
-- defect, and the gap it sits in is two orders of magnitude wide.
SELECT
    count() AS rows,
    uniqExact((siri_snapshot_id, siri_ride_stop_id, recorded_at_time)) AS readings,
    round(count() / uniqExact((siri_snapshot_id, siri_ride_stop_id, recorded_at_time)), 4) AS ratio,
    throwIf(
        count() > uniqExact((siri_snapshot_id, siri_ride_stop_id, recorded_at_time)) * 1.01,
        'siri_vehicle_location holds each reading more than once: see mode 2 in ingest/verify.sql'
    ) AS ok
FROM siri_vehicle_location
WHERE recorded_at_time >= toDateTime({from:Date})
  AND recorded_at_time < toDateTime({to:Date}) + INTERVAL 1 DAY;

-- The two tables the fact table points at. Scoped by id and not by date on
-- purpose: neither has a usable time column — siri_ride.scheduled_start_time is
-- an argMin the feed can revise, and siri_ride_stop has no time at all — while
-- both are sorted by id, which is the column the failure corrupts.
--
-- Each of the four reads the base table and never a projection. A gate must not
-- depend on a projection being fresh, and here that is not hypothetical: a
-- lightweight delete leaves projections serving the rows it deleted, so the
-- natural-key count for 2026-08-01's rides read 1,732,181 through
-- `by_siri_ride` and 2,860 without it. ingest/repair.sql uses heavy mutations
-- so the two agree; this setting means the gate is right even when something
-- else has not been.

SELECT
    sum(extra) AS extra_rows,
    count() AS duplicated_ids,
    throwIf(sum(extra) > 0, 'duplicate ids in siri_ride') AS ok
FROM (
    SELECT count() - 1 AS extra
    FROM siri_ride
    WHERE id >= {ride_from_id:Int64}
    GROUP BY id
    HAVING count() > 1
) SETTINGS optimize_use_projections = 0;

SELECT
    sum(extra) AS extra_rows,
    count() AS duplicated_keys,
    throwIf(sum(extra) > 0, 'duplicate natural keys in siri_ride') AS ok
FROM (
    SELECT count() - 1 AS extra
    FROM siri_ride
    WHERE id >= {ride_from_id:Int64}
    GROUP BY siri_route_id, journey_ref, vehicle_ref
    HAVING count() > 1
) SETTINGS optimize_use_projections = 0;

SELECT
    sum(extra) AS extra_rows,
    count() AS duplicated_ids,
    throwIf(sum(extra) > 0, 'duplicate ids in siri_ride_stop') AS ok
FROM (
    SELECT count() - 1 AS extra
    FROM siri_ride_stop
    WHERE id >= {ride_stop_from_id:Int64}
    GROUP BY id
    HAVING count() > 1
) SETTINGS optimize_use_projections = 0;

-- The one that explains the doubling, and the only check here that was failing
-- silently rather than loudly: 9,161,623 duplicate ids sat in this table for
-- three weeks while every gate was green, because the gate did not look at it,
-- and the duplicate natural keys underneath them were what doubled the fact
-- table.
SELECT
    sum(extra) AS extra_rows,
    count() AS duplicated_keys,
    throwIf(sum(extra) > 0, 'duplicate natural keys in siri_ride_stop') AS ok
FROM (
    SELECT count() - 1 AS extra
    FROM siri_ride_stop
    WHERE id >= {ride_stop_from_id:Int64}
    GROUP BY siri_ride_id, siri_stop_id, `order`
    HAVING count() > 1
) SETTINGS optimize_use_projections = 0;
