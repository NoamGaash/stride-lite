# Hasadna's infrastructure

Nothing here is deployed from this directory. Hasadna runs its projects from two repositories
of its own, where its maintainers review every change:

| What | Where |
|---|---|
| The ClickHouse server (Kamatera, internal network only), its config and its backup bucket | [hasadna-iac](https://github.com/hasadna/hasadna-iac), `modules/openbus/stride_lite.tf` ([#5](https://github.com/hasadna/hasadna-iac/pull/5)) |
| The API, the migrations and the ingest jobs, as images that ArgoCD syncs | [hasadna-k8s](https://github.com/hasadna/hasadna-k8s), `apps/openbus` |

The image is built from this repository by CI. Copies of those files are deliberately not kept
here, because they would drift from what Hasadna actually runs.

## What the image reads

| Variable | For |
|---|---|
| `CH_URL`, `CH_USER`, `CH_PASSWORD`, `CH_DB` | the API (`api/src/ch.ts`) |
| `CH_CLIENT` | the scripts, e.g. `clickhouse client --host … --user … --password …` |
| `BACKUP_URL` | `scripts/first-load.sh` restores from it into an empty database |
| `ARCHIVE_BUCKET` | `scripts/gtfs-archive.sh`, `scripts/naim-rt-request.sh` |
| `API_URL` | `scripts/check-production.sh` |
