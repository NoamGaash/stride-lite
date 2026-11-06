# Table migrations

Everything else in this repository converges: `db/schema.sql` creates tables that are not
there, and every view is replaced outright on each deploy. Tables cannot work that way,
because they hold the data — so a change to a table that already exists goes here, as one
numbered file that runs exactly once. `scripts/migrate.sh` keeps the record, in
`schema_migrations`.

```
db/migrations/001_add_siri_ride_duration_source.sql
```

Three rules, each because of something ClickHouse does not give us:

1. **Numbered and append-only.** Filename order is apply order. An applied file is never
   edited — its name is already in `schema_migrations`, so an edit would never run.
2. **Safe to re-run after a partial failure.** There is no transaction around DDL and no
   rollback, so a file that fails half way leaves the earlier statements applied. Write
   `ADD COLUMN IF NOT EXISTS` and `DROP COLUMN IF EXISTS` and a retry finishes the job.
3. **A migration that changes what a view reads replaces that view too.** Views are applied
   after migrations on every deploy, so adding a column is enough; renaming or dropping one
   a view reads is not, and the migration has to carry the new view body with it.

`db/schema.sql` stays the shape of a new database. A migration that adds a column belongs in
both: here for the databases that exist, there for the ones that do not yet.

## What a migration can reach

`scripts/apply-schema.sh` runs `db/schema.sql`, then this directory, then `db/views.sql`. So a
migration can alter the 16 tables that `db/schema.sql` defines — the ones that mirror the
production dump — and that is what the ordering is for: a view applied afterwards may read a
column a migration just added.

`gtfs_rides_agg_by_hour` is the exception, because it is defined in `db/views.sql` and does not
exist yet when migrations run. It is also derived, so it never needs altering: a migration that
has to change its shape drops it, and the same deploy's `db/views.sql` recreates it and its
refresh refills it — measured at 92 seconds for 60 million rows.

```sql
DROP TABLE IF EXISTS gtfs_rides_agg_by_hour;
```

Attempting `ALTER TABLE gtfs_rides_agg_by_hour` in a migration fails with
`Code: 60 … Could not find table` on a fresh database, which is how this was found.
