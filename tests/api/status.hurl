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
jsonpath "$[0].duplicate_ids" == 0
jsonpath "$[0].rides" > 0
