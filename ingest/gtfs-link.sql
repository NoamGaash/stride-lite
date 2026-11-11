-- Which GTFS ride each SIRI ride ran, decided as production decides it in
-- open-bus-stride-etl's siri/update_rides_gtfs.py:
--
--   journey_gtfs_ride_id         the GTFS ride whose journey_ref is the SIRI
--                                one rewritten (2025-03-14-17336336 is
--                                17336336_140325), on a GTFS route of the
--                                ride's day.
--   route_gtfs_ride_id           a GTFS ride of the same operator and line, on
--                                the ride's day, starting less than 1, else 3,
--                                else 5 minutes from the SIRI scheduled start.
--   gtfs_ride_id                 the journey match if there is one, else the
--                                route match.
--   scheduled_time_gtfs_ride_id  a GTFS ride of the same operator and line, on
--                                the ride's day or the next, starting exactly
--                                at the SIRI scheduled start.
--
-- "The ride's day" is the UTC date of its scheduled start, because that is what
-- production's date_trunc gives on its UTC database. Where production takes
-- whichever row its UPDATE ... FROM meets first, this takes the nearest start
-- and then the lowest id, so the answer is at least stable. Production also
-- links only a ride whose duration it has measured; this links every ride,
-- because the match reads nothing that changes after the ride is created.
--
-- Written to siri_ride_gtfs, a table of its own like siri_ride_duration,
-- because siri_ride is only ever appended to.
--
-- Rides are taken by the date their journey_ref starts with, which the
-- by_natural_key projection on siri_ride is sorted by; scheduled_start_time has
-- no index. The id bounds turn that into a primary-key range on siri_ride.
CREATE OR REPLACE VIEW enrich_gtfs_link_src AS
WITH
    toString({from:Date}) AS lo,
    toString({to:Date} + 1) AS hi,
    (SELECT (min(id), max(id)) FROM siri_ride WHERE journey_ref >= lo AND journey_ref < hi) AS ids,
    loaded AS (
        SELECT DISTINCT date FROM gtfs_route
        WHERE date BETWEEN {from:Date} - 1 AND {to:Date} + 1
    ),
    rides AS (
        SELECT r.id AS siri_ride_id,
               r.journey_ref AS journey_ref,
               assumeNotNull(r.scheduled_start_time) AS scheduled_start_time,
               toDate(r.scheduled_start_time, 'UTC') AS day,
               sr.operator_ref AS operator_ref,
               sr.line_ref AS line_ref
        FROM siri_ride AS r
        INNER JOIN siri_route AS sr ON sr.id = r.siri_route_id
        WHERE r.id BETWEEN ids.1 AND ids.2
          AND r.journey_ref >= lo AND r.journey_ref < hi
          AND r.scheduled_start_time IS NOT NULL
          AND r.id NOT IN (SELECT siri_ride_id FROM siri_ride_gtfs
                           WHERE siri_ride_id BETWEEN ids.1 AND ids.2)
          AND toDate(r.scheduled_start_time, 'UTC') IN loaded
    ),
    planned AS (
        SELECT g.id AS gtfs_ride_id,
               g.journey_ref AS journey_ref,
               g.start_time AS start_time,
               gr.date AS day,
               gr.operator_ref AS operator_ref,
               gr.line_ref AS line_ref
        FROM gtfs_ride AS g
        INNER JOIN gtfs_route AS gr ON gr.id = g.gtfs_route_id
        WHERE g.gtfs_route_id IN (SELECT id FROM gtfs_route
                                  WHERE date BETWEEN {from:Date} - 1 AND {to:Date} + 2)
    ),
    by_journey AS (
        SELECT r.siri_ride_id AS siri_ride_id, toNullable(min(p.gtfs_ride_id)) AS gtfs_ride_id
        FROM rides AS r
        INNER JOIN planned AS p
            ON p.journey_ref = concat(splitByChar('-', r.journey_ref)[4], '_',
                                      splitByChar('-', r.journey_ref)[3],
                                      splitByChar('-', r.journey_ref)[2],
                                      substring(splitByChar('-', r.journey_ref)[1], 3))
           AND p.day = r.day
        GROUP BY siri_ride_id
    ),
    by_line AS (
        SELECT r.siri_ride_id AS siri_ride_id,
               argMinIfOrNull(p.gtfs_ride_id,
                   (abs(dateDiff('second', p.start_time, r.scheduled_start_time)), p.gtfs_ride_id),
                   p.day = r.day
                   AND abs(dateDiff('second', p.start_time, r.scheduled_start_time)) < 300) AS route_gtfs_ride_id,
               minIfOrNull(p.gtfs_ride_id,
                   p.start_time = r.scheduled_start_time
                   AND p.day BETWEEN r.day AND r.day + 1) AS scheduled_time_gtfs_ride_id
        FROM rides AS r
        INNER JOIN planned AS p
            ON p.operator_ref = r.operator_ref AND p.line_ref = r.line_ref
        GROUP BY siri_ride_id
    )
SELECT r.siri_ride_id AS siri_ride_id,
       toDate(substring(r.journey_ref, 1, 10)) AS journey_date,
       j.gtfs_ride_id AS journey_gtfs_ride_id,
       l.route_gtfs_ride_id AS route_gtfs_ride_id,
       coalesce(j.gtfs_ride_id, l.route_gtfs_ride_id) AS gtfs_ride_id,
       l.scheduled_time_gtfs_ride_id AS scheduled_time_gtfs_ride_id
FROM rides AS r
LEFT JOIN by_journey AS j ON j.siri_ride_id = r.siri_ride_id
LEFT JOIN by_line AS l ON l.siri_ride_id = r.siri_ride_id;

-- One journey date per refresh, newest first, which also walks back through
-- history on its own. A date is taken once it is final:
--
--   * its rides' scheduled starts fall on it or, in UTC, the day before, and a
--     scheduled-time match may sit on the next day's GTFS, so all three days
--     of GTFS are loaded;
--   * every snapshot its rides can appear in has been enriched, which is true
--     once a snapshot two days later has;
--   * SIRI ran that day. A date whose rides all went unmatched still has rows,
--     so this is what keeps the view from choosing an empty date forever.
--
-- A date is done once siri_ride_gtfs holds rows for it. Linking waits for the
-- next day's GTFS, so yesterday's rides are linked the morning after.
CREATE OR REPLACE MATERIALIZED VIEW enrich_gtfs_link
REFRESH EVERY 5 MINUTE
APPEND TO siri_ride_gtfs AS
WITH
    (SELECT groupUniqArray(assumeNotNull(date)) FROM gtfs_route WHERE date IS NOT NULL) AS gtfs,
    (SELECT toDate(replaceAll(substring(max(snapshot_id), 1, 10), '/', '-'))
     FROM siri_snapshot) AS enriched_to,
    (SELECT maxOrNull(d)
     FROM (SELECT DISTINCT toDate(replaceAll(substring(siri_snapshot_id, 1, 10), '/', '-')) AS d
           FROM siri_snapshot_seen)
     WHERE has(gtfs, d - 1) AND has(gtfs, d) AND has(gtfs, d + 1)
       AND d + 2 <= enriched_to
       AND d NOT IN (SELECT DISTINCT journey_date FROM siri_ride_gtfs)) AS next_date
SELECT * FROM enrich_gtfs_link_src(from = ifNull(next_date, toDate(0)), to = ifNull(next_date, toDate(0)));
