GET {{api}}/siri_snapshots/list
[Query]
order_by: snapshot_id desc
limit: 1
HTTP 200
[Asserts]
jsonpath "$[0].snapshot_id" == "2025/03/14/08/59"

GET {{api}}/siri_rides/list
[Query]
scheduled_start_time_from: 2025-03-14T08:00:00+00:00
scheduled_start_time_to: 2025-03-14T09:00:00+00:00
order_by: id asc
limit: 1000
HTTP 200
[Asserts]
jsonpath "$" count > 100
jsonpath "$[?(@.scheduled_start_time < '2025-03-14T08:00:00+00:00')]" not exists
[Captures]
siri_ride_id: jsonpath "$[?(@.duration_minutes > 0)].id" nth 0

# A ride's duration is the span between the two locations it names.
GET {{api}}/siri_rides/get
[Query]
id: {{siri_ride_id}}
HTTP 200
[Asserts]
jsonpath "$.duration_minutes" > 0
jsonpath "$.duration_minutes" < 300
[Captures]
first_location: jsonpath "$.first_vehicle_location_id"

GET {{api}}/siri_vehicle_locations/get
[Query]
id: {{first_location}}
HTTP 200
[Asserts]
jsonpath "$.recorded_at_time" startsWith "2025-03-14T08"
jsonpath "$.lat" > 29
jsonpath "$.lat" < 34

GET {{api}}/siri_ride_stops/list
[Query]
siri_ride_ids: {{siri_ride_id}}
HTTP 200
[Asserts]
jsonpath "$" count > 0
jsonpath "$[?(@.siri_ride_id != {{siri_ride_id}})]" not exists

GET {{api}}/siri_vehicle_locations/list
[Query]
recorded_at_time_from: 2025-03-14T08:30:00+00:00
recorded_at_time_to: 2025-03-14T08:31:00+00:00
get_count: true
HTTP 200
[Asserts]
body toInt > 100
