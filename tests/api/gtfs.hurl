GET {{api}}/gtfs_agencies/list
[Query]
date_from: 2025-03-14
date_to: 2025-03-14
HTTP 200
[Asserts]
jsonpath "$" count == 4
jsonpath "$[*].agency_name" contains "תנופה"

GET {{api}}/gtfs_routes/list
[Query]
date_from: 2025-03-14
date_to: 2025-03-14
operator_refs: 34
limit: 1000
HTTP 200
[Asserts]
jsonpath "$" count > 0
jsonpath "$[?(@.operator_ref != 34)]" not exists
jsonpath "$[?(@.date != '2025-03-14')]" not exists
[Captures]
route_id: jsonpath "$[0].id"

GET {{api}}/gtfs_routes/get
[Query]
id: {{route_id}}
HTTP 200
[Asserts]
jsonpath "$.id" == {{route_id}}
jsonpath "$.operator_ref" == 34

# Hebrew collation ignores punctuation, as production's does: "אלמשאהד"
# sorts before "א סאפא" because the space does not count.
GET {{api}}/gtfs_routes/list
[Query]
date_from: 2025-03-14
date_to: 2025-03-14
operator_refs: 49,50,51
order_by: route_long_name asc
limit: 2
HTTP 200
[Asserts]
jsonpath "$[0].route_long_name" startsWith "אלמשאהד"
jsonpath "$[1].route_long_name" startsWith "א סאפא"

GET {{api}}/gtfs_rides/list
[Query]
gtfs_route_id: {{route_id}}
order_by: start_time asc
HTTP 200
[Asserts]
jsonpath "$" count > 0
jsonpath "$[?(@.gtfs_route_id != {{route_id}})]" not exists
[Captures]
ride_id: jsonpath "$[0].id"

GET {{api}}/gtfs_ride_stops/list
[Query]
gtfs_ride_ids: {{ride_id}}
order_by: stop_sequence asc
HTTP 200
[Asserts]
jsonpath "$" count > 1
jsonpath "$[0].stop_sequence" == 1
[Captures]
stop_id: jsonpath "$[0].gtfs_stop_id"

GET {{api}}/gtfs_stops/get
[Query]
id: {{stop_id}}
HTTP 200
[Asserts]
jsonpath "$.lat" > 29
jsonpath "$.lat" < 34
jsonpath "$.lon" > 34
jsonpath "$.lon" < 36
