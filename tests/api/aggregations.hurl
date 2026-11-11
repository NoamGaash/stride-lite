GET {{api}}/gtfs_rides_agg/group_by
[Query]
date_from: 2025-03-14
date_to: 2025-03-14
group_by: operator_ref
HTTP 200
[Asserts]
jsonpath "$" count == 4
# Production's SQL has no ORDER BY, but Postgres groups by sorting, so every
# client has always seen the rows in group order.
jsonpath "$[0].operator_ref" == 34
jsonpath "$[3].operator_ref" == 51
jsonpath "$[*].operator_ref" contains 34
jsonpath "$[?(@.total_planned_rides <= 0)]" not exists
# Executed rides come from enrich_gtfs_link_src. Production never linked
# Pi Day, so these are ours: 231 is what the fixture's rides link to.
jsonpath "$[0].total_actual_rides" == 231

GET {{api}}/gtfs_rides_agg/group_by
[Query]
date_from: 2025-03-14
date_to: 2025-03-14
group_by: gtfs_route_hour,operator_ref
HTTP 200
[Asserts]
jsonpath "$[0].gtfs_route_hour" == "2025-03-14"
jsonpath "$[0].operator_ref" == 34

# Production's trim(lower(to_char(hour, 'DAY'))). Pi Day 2025 was a Friday.
GET {{api}}/gtfs_rides_agg/group_by
[Query]
date_from: 2025-03-14
date_to: 2025-03-14
group_by: day_of_week
HTTP 200
[Asserts]
jsonpath "$" count == 1
jsonpath "$[0].day_of_week" == "friday"
