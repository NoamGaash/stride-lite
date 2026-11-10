GET {{api}}/gtfs_rides_agg/group_by
[Query]
date_from: 2025-03-14
date_to: 2025-03-14
group_by: operator_ref
HTTP 200
[Asserts]
jsonpath "$" count == 4
jsonpath "$[*].operator_ref" contains 34
jsonpath "$[?(@.total_planned_rides <= 0)]" not exists
