# Errors as production words them, since clients match on them.

GET {{api}}/gtfs_routes/list
[Query]
date_from: 2025-03-14
date_to: 2025-03-14
order_by: no_such_field asc
HTTP 500
[Asserts]
jsonpath "$.message" == "type object 'GtfsRoute' has no attribute 'no_such_field'"

GET {{api}}/gtfs_routes/get
[Query]
id: 999999999
HTTP 404

GET {{api}}/no/such/endpoint
HTTP 404
