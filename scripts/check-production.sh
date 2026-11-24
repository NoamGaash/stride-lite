#!/usr/bin/env bash
# Checks a running deployment from the outside, the way a user meets it: is the
# data fresh, is the database healthy, and do the answers still match
# production's. Run by hand after a deploy or a change to the node, e.g.
#
#   API_URL=https://example.org scripts/check-production.sh
#   API_URL=... SKIP_DIFF=1 scripts/check-production.sh  # without the 2-minute comparison
#
# deploy/<environment>/bin/check-production.sh runs it against that environment.
#
# Read-only, and it asks production (the differential suite) once per case,
# spaced out, as api/tests/differential.test.ts does. Exits non-zero if any
# check failed; every check runs either way.
set -uo pipefail
cd "$(dirname "$0")/.."
API=${API_URL:?set API_URL to the deployment to check}
failed=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; failed=1; }
get() { curl -sS --fail --max-time 60 "$API$1"; }

# 1. SIRI arrives: the newest snapshot is minutes old. Hasadna's requester
#    writes one a minute and the ingest picks it up within two.
if latest=$(get '/siri_snapshots/list?limit=1&order_by=id%20desc' \
            | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["snapshot_id"])'); then
  age=$(( ( $(date -u +%s) - $(date -u -d "$(echo "$latest" | sed -E 's|(....)/(..)/(..)/(..)/(..)|\1-\2-\3 \4:\5|')" +%s) ) / 60 ))
  if [ "$age" -le 15 ]; then pass "newest SIRI snapshot $latest, $age min old"
  else fail "newest SIRI snapshot $latest is $age min old"; fi
else
  fail "could not read the newest SIRI snapshot"
fi

# 2. GTFS arrives: today's routes are loaded (ingest/gtfs.sh, 04:20 UTC).
today=$(date -u +%F)
if [ "$(get "/gtfs_routes/list?date_from=$today&date_to=$today&limit=1" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" = 1 ]; then
  pass "GTFS routes for $today"
else
  fail "no GTFS routes for $today"
fi

# 3. The database: no refreshable view failing, nothing over the memory limit,
#    and how the API itself fared in the last hour.
if metrics=$(get /ops/metrics); then
  echo "$metrics" | python3 -c '
import json, sys
d = json.load(sys.stdin)
bad = [r["view"] + ": " + r["exception"][:160] for r in d["refreshes"] if r["exception"]]
for b in bad: print("FAIL  refresh " + b)
if not bad: print("PASS  %d refreshable views, none failing" % len(d["refreshes"]))
mem = [e for e in d["errors_last_day"] if e["name"] == "MEMORY_LIMIT_EXCEEDED"]
for e in mem: print("FAIL  MEMORY_LIMIT_EXCEEDED x%d in the last day, last at %s" % (e["value"], e["last_error_time"]))
if not mem: print("PASS  no MEMORY_LIMIT_EXCEEDED in the last day")
s = d["server"]
print("INFO  ClickHouse up %d min, resident %.2f GB, peak %.2f GB of %.2f GB" % (
    s["uptime_seconds"] // 60, s["MemoryResident"] / 1e9, s["MemoryResidentMax"] / 1e9, s["OSMemoryTotal"] / 1e9))
for r in d["api_requests_last_hour"]:
    if r["endpoint"] and r["errors"]:
        print("INFO  %s: %d of %d failed in the last hour, p95 %d ms" % (r["path"], r["errors"], r["requests"], r["p95_ms"]))
sys.exit(1 if bad or mem else 0)
' || failed=1
else
  fail "could not read /ops/metrics"
fi

# 4. Answers match production's, in the window both databases hold.
if [ "${SKIP_DIFF:-0}" = 1 ]; then
  echo "SKIP  differential suite"
else
  out=$(cd api && { [ -d node_modules ] || npm ci --silent; } && LOCAL_API=$API npx vitest run tests/differential.test.ts 2>&1)
  rc=$?
  echo "$out" | grep -E '[✓×] |Tests ' | sed -E 's/^ *//; s/^✓/PASS /; s/^×/FAIL /'
  [ "$rc" = 0 ] || failed=1
fi

[ "$failed" = 0 ] && echo "all checks passed" || echo "some checks failed"
exit "$failed"
