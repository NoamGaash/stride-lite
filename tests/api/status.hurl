# Freshness and health of what was loaded: tests/api/fixture.sh holds the
# 08:00 UTC hour of 2025-03-14 and that day's GTFS.

GET {{api}}/status
HTTP 200
[Asserts]
jsonpath "$.newest_snapshot" == "2025/03/14/08/59"
jsonpath "$.newest_gtfs_date" == "2025-03-14"
jsonpath "$.vehicle_locations" > 0
jsonpath "$.refresh_tasks_failing" == 0

GET {{api}}/coverage
HTTP 200
[Asserts]
jsonpath "$" count == 1
jsonpath "$[0].day" == "2025-03-14"
jsonpath "$[0].snapshots" == 60
jsonpath "$[0].empty_snapshots" == 1
jsonpath "$[0].duplicate_ids" == 0
jsonpath "$[0].rides" > 0
jsonpath "$[0].rides_linked_to_gtfs" == 273

# The node's own load and memory, kept a week by db/node-metrics.sql. Its view
# samples once on creation, so even a database a minute old has one reading.
GET {{api}}/ops/metrics
HTTP 200
[Asserts]
jsonpath "$.history" count == 3
jsonpath "$.history[0].window" == "hour"
jsonpath "$.history[1].window" == "day"
jsonpath "$.history[2].window" == "week"
jsonpath "$.history[0].samples" >= 1
jsonpath "$.history[0].load1_avg" exists
jsonpath "$.history[0].load1_p95" exists
jsonpath "$.history[0].memory_used_avg" > 0
jsonpath "$.history[0].memory_used_p95" > 0
jsonpath "$.history[0].load1_max" exists
jsonpath "$.history[0].memory_used_max" > 0
