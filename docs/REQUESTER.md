# A second SIRI requester

[עברית](REQUESTER.he.md)

Everything here derives from the SIRI snapshots Hasadna's requester writes to
`openbus-stride-public/stride-siri-requester/`, one file a minute. When that requester gets
nothing, the data for those minutes is never written, here or in production: SIRI is a
real-time interface, so a missed minute most likely cannot be requested again *(unverified)*.

## Why: the gap of 18–19 November 2026

Files in the source bucket per UTC hour, counted from its public listing on 2026-11-20:

| Day | Hours with files | Files |
| --- | --- | --- |
| 2026-11-18 | 00–19 full, 20:00 has 29 | 1,214 of ~1,430 |
| 2026-11-19 | 09:00 has 14, then 15–23 full | 547 of ~1,430 |
| 2026-11-20 | every hour full | — |

So nothing was written from **2026-11-18 20:30 UTC to 2026-11-19 15:00 UTC**, about 18 hours,
apart from 14 minutes. Production's `/siri_vehicle_locations/list` is empty for the same
hours, so the gap is at the source, not in this project's ingest. The cause was a fault on the
Ministry's server, not in Hasadna's requester.

## What is built

[`deploy/aws/bin/siri-request.sh`](../deploy/aws/bin/siri-request.sh), on the AWS node, asks
the Ministry every 15 seconds — the ICD (SM 2.8, §7.15 and §7.18) builds a new answer every
15 seconds and allows a request that often, where Hasadna asks once a minute. Each answer is
kept brotli-compressed at `s3://openbus-mot-archive/siri/YYYY/MM/DD/HH/MM/SS.br`:

- it is a `curl` on a systemd timer, not a daemon: a run is killed at 14 s, so it cannot hang;
- the key reaches `curl` on stdin, never on a command line;
- an answer is kept only if its `ResponseTimestamp` is under two minutes old, and the Ministry's
  fallback host is asked when the first fails;
- an upload that fails is kept on disk and retried by the next run.

**It runs once the Ministry's key is in `/etc/stride-lite/node.env`** as `OPEN_BUS_MOT_KEY`;
the next deploy enables its timer. Until then the timer is off.

## The constraint: a fixed source address

The Ministry answers SIRI requests only from addresses it has allowlisted. The AWS node's
Elastic IP is a separate resource that survives the instance being replaced, and it is the
address submitted to the Ministry for registration.

Hasadna's requester sends through `hasadna-proxy1`, a squid server whose public IP is the one
allowlisted for Hasadna. It listens only on Hasadna's private network (`lan-82145-hasadna`)
([hasadna-iac `modules/hasadna/proxy.tf`](https://github.com/hasadna/hasadna-iac/blob/main/modules/hasadna/proxy.tf)).
A second requester behind the same proxy would share its single point of failure, and together
with Hasadna's would ask more often than the ICD allows. So a requester inside Hasadna's
infrastructure stays Hasadna's own; features go to it as pull requests.

## Options that were weighed

Prices are public list prices. Nothing below is what Hasadna actually pays.

| Option | Monthly cost | Why not |
| --- | --- | --- |
| Lambda in a VPC behind a NAT Gateway with an Elastic IP | ~$33 for the NAT Gateway alone *(list price from memory, not checked)* | The NAT Gateway costs more than everything else here together |
| A timer on a stride-lite server inside Hasadna | $0 extra | Not independent: an outage of Hasadna's infrastructure takes both requesters down |
| A spot instance, with automatic failover of the Elastic IP | ~$0.1 | A Lambda, two instances and states that can only be tested with simulated events |
| A tiny always-on server running only the requester | Lightsail $5 incl. static IP ([price page](https://aws.amazon.com/lightsail/pricing/), 2026-11-20) | A second server to keep, while the AWS node already has a fixed address |
| Another party's requester, used to fill gaps | $0 | No say in their format or uptime |
