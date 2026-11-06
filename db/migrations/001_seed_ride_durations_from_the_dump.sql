-- Moves the durations production did measure into the table the API now reads,
-- so there is one source for them and nothing has to coalesce two.
--
-- The dump holds 56,370,994 rides with a duration and nothing measured after
-- December 2024 — production's own pass decayed through autumn 2024 (97% of
-- 2024-09, 24% of 2024-10, 5% of 2024-11) and stopped at 7 rides out of
-- 3,086,370 in 2024-12. Everything from 2025-01 on is zero. So this is history
-- that cannot be recomputed for the years whose locations production has since
-- deleted, and it is worth carrying over.
--
-- What is NOT carried over is the 7,698 rides with duration_minutes = 0 and no
-- first_vehicle_location_id. That pair is the signature of
-- add_ride_durations.py's second pass, which writes a zero for rides whose
-- locations it never got to — a measurement that was never measured. They
-- become NULL here, which is what not knowing looks like. The other 782,460
-- zeros do have both ids and are kept: at 1.4% of the measured rides they match
-- the 1.9% this implementation computes for a day of its own, so they are rides
-- that reported inside one minute rather than rides that were given up on.
--
-- Re-runnable, per the rule in db/migrations/README.md: the NOT IN makes a
-- second pass insert nothing, which is what a retry after a partial failure
-- needs.
INSERT INTO siri_ride_duration
SELECT
    id AS siri_ride_id,
    first_vehicle_location_id,
    last_vehicle_location_id,
    duration_minutes
FROM siri_ride
WHERE duration_minutes IS NOT NULL
  AND first_vehicle_location_id IS NOT NULL
  AND last_vehicle_location_id IS NOT NULL
  AND id NOT IN (SELECT siri_ride_id FROM siri_ride_duration);
