-- Snapshots the requester wrote with no vehicle in them: a gap at the source,
-- counted apart from the snapshots that carried data so it is not mistaken for one.
-- After `snapshots` because ingest/health.sql inserts with SELECT *, by position.
ALTER TABLE ingest_day_health ADD COLUMN IF NOT EXISTS empty_snapshots UInt32 AFTER snapshots;
