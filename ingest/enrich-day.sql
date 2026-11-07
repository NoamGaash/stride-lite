-- The per-day tail of an enrichment pass: what a day's rides took, and what the
-- day turned out to be worth.
--
-- Split from enrich-once.sql because the two have different natural batch
-- sizes. The six steps there are driven by which marks are cleared and get
-- cheaper per day the more days they cover; these two are per-day by
-- definition — a duration needs a window, and a health row is a day's verdict.
--
-- There is deliberately no "the chain must be off" guard here, unlike in
-- enrich-once.sql and repair.sql. Neither statement below mints an id:
-- siri_ride_duration is keyed on siri_ride_id and ingest_day_health on the day,
-- both of which come from the data. Two of these running at once would write
-- the same rows twice, which a ReplacingMergeTree and an idempotent insert
-- absorb — not two different rows under one id, which is the failure the guard
-- exists for.
--
--   clickhouse client --database stride --multiquery \
--     --param_day=2026-06-02 < ingest/enrich-day.sql

-- The durations of the day just loaded. This has to be told which day: see the
-- comment on enrich_duration_src for why the landing table cannot say.
--
-- The window reaches six hours back so a ride that departed before midnight is
-- measured whole, and `settled_before` is the day's own end rather than now():
-- the last six hours of the day are left to the next day's run, which walks
-- over them again. That is why both drivers go oldest-day-first.
INSERT INTO siri_ride_duration
SELECT * FROM enrich_duration_src(
    from = toDateTime({day:Date}) - INTERVAL 6 HOUR,
    to = toDateTime({day:Date}) + INTERVAL 30 HOUR,
    settled_before = toDateTime({day:Date}) + INTERVAL 24 HOUR);

-- What the day turned out to be worth, recorded where the API can serve it.
-- Last, so it measures the durations just written as well as the rows
-- enrich-once.sql wrote before this file was called.
INSERT INTO ingest_day_health SELECT * FROM ingest_day_health_src(day = {day:Date});
