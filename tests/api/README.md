# API tests

Each `*.hurl` file here is a sequence of requests and assertions against the
API running on a small real database: the 08:00 UTC hour of 2025-03-14 (Pi
Day, a Friday and Purim) and that day's GTFS, cut to four operators.

```sh
CH_CLIENT="clickhouse client" tests/api/fixture.sh load     # into stride_test
(cd api && CH_DB=stride_test npm start) &
hurl --test --jobs 1 --variable api=http://127.0.0.1:8080 tests/api
```

A new test is a new request in a `.hurl` file, or a new file: the folder is
run whole. See [hurl.dev](https://hurl.dev) for the syntax.

`fixture.sh build` re-cuts the fixture from the archive. It downloads from
Hasadna's bucket, which they pay for, so run it only to change what the fixture
holds, and commit what it writes.
