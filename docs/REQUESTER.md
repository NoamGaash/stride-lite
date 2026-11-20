# A second SIRI requester: options

[עברית](REQUESTER.he.md)

Everything here derives from the SIRI snapshots Hasadna's requester writes to
`openbus-stride-public/stride-siri-requester/`, one file a minute. When that requester stops,
the data for those minutes is never written, here or in production. This page weighs where a
second, independent requester could run. Nothing on it is built yet.

## Why: the gap of 18–19 November 2026

Files in the source bucket per UTC hour, counted from its public listing on 2026-11-20:

| Day | Hours with files | Files |
| --- | --- | --- |
| 2026-11-18 | 00–19 full, 20:00 has 29 | 1,214 of ~1,430 |
| 2026-11-19 | 09:00 has 14, then 15–23 full | 547 of ~1,430 |
| 2026-11-20 | every hour full | — |

So nothing was written from **2026-11-18 20:30 UTC to 2026-11-19 15:00 UTC**, about 18 hours,
apart from 14 minutes. Production's `/siri_vehicle_locations/list` is empty for the same
hours, so the gap is at the source, not in this project's ingest. *Unverified:* SIRI is a
real-time interface, so those minutes most likely cannot be requested again.

A second requester, writing to its own bucket, would have covered them.

Where the gap came from is not known yet. Airflow does not show it: the requester is not a
DAG but a Kubernetes Deployment, `siri-requester` in the `openbus` namespace
([hasadna-k8s](https://github.com/hasadna/hasadna-k8s/blob/master/apps/openbus/templates/siri-requester-deployment.yaml)).
Its pod's logs and restarts, and the proxy below, are where to look.

## The constraint: a fixed source address

The Ministry of Transport answers SIRI requests only from addresses it has allowlisted. A
second requester needs a stable public IPv4 address, registered with the Ministry. The
maintainer can ask for one or more additional addresses.

Hasadna's requester does not own that address. It sends through `hasadna-proxy1`, a squid
server set up by hand whose public IP is the allowlisted one
([hasadna-iac `modules/hasadna/proxy.tf`](https://github.com/hasadna/hasadna-iac/blob/main/modules/hasadna/proxy.tf)).
**So a second requester needs an address of its own.** Sending through the same proxy would
share its single point of failure, which is the failure this page is about.

*Open questions:*
- whether the Ministry requires an Israeli address;
- how long registering one takes. An outside developer reported on Hasadna's Slack that a
  request sent on 2026-10-29, with a reminder on 2026-11-03, had no reply by 2026-11-20.
  Start the request before building anything.

## Options

Prices are public list prices, as labelled. Nothing below is what Hasadna actually pays.

| | Option | Monthly cost | Depends on Hasadna | Stays up when… | Moving parts |
| --- | --- | --- | --- | --- | --- |
| 1 | Lambda + scheduler, in a VPC behind a NAT Gateway with an Elastic IP | ~$33 for the NAT Gateway alone, plus traffic *(list price from memory, not checked)* | No | AWS is up | VPC, subnets, NAT, Lambda, scheduler |
| 2 | A systemd timer on the stride-lite node at Hasadna (Kamatera) | $0 extra | **Yes** | that server is up | One unit |
| 3 | A timer on the AWS node, kept as a spot instance for staging, using its existing Elastic IP | $0 extra (the IP: ~$3.6 while stopped) | No | **the spot instance is running** | One unit |
| 4 | Option 3, plus an automatic failover to a tiny instance when the spot stops | ~$0.1 (a stopped tiny instance's disk) | No | almost always; ~1–2 minutes lost per switch | EventBridge, Lambda, two instances, moving the EIP |
| 5 | **A tiny always-on server running only the requester** | Lightsail **$5** incl. static IP *([price page](https://aws.amazon.com/lightsail/pricing/), 2026-11-20)*; Hetzner from €5.49 excl. VAT, IPv4 price not stated *([page](https://www.hetzner.com/cloud/))*; Oracle Cloud Always Free *(unverified)* | No | that small server is up | One server, one unit |

### Notes on each

1. **Lambda.** Lambda leaves AWS from shifting addresses, so it needs a NAT Gateway to have a
   fixed one. The NAT Gateway costs more than everything else on this page together.
2. **Hasadna's node.** Free at the margin, but it is not independent: an outage of Hasadna's
   infrastructure can take down both requesters. *Unverified:* Kamatera's address belongs to
   the server for its lifetime, and Terraform declares no reserved address. A rebuilt server
   would most likely get a new address, which the Ministry would then have to register again.
3. **Spot staging.** The Elastic IP is a separate resource, so it survives the instance being
   replaced. It sends nothing while the instance is stopped, though: during a spot
   interruption, this requester is down. Two settings make this workable:
   - **interruption behaviour `stop`, with a persistent request:** the data volume and the
     IP association survive, and the instance returns when there is capacity;
   - **`prevent_destroy` on the Elastic IP:** a released Elastic IP never comes back.
4. **Failover.** Spot interruptions arrive as EventBridge events. A small Lambda would start
   a pre-built stopped `t4g.nano` and move the Elastic IP to it, then move it back. That is
   about 80–100 lines of Terraform and ~30 of Lambda. The hard parts:
   - states where both instances are up, or an event was missed, so the Lambda must check
     what is actually running rather than trust the event;
   - a spot interruption cannot be requested, so this would be tested only with simulated
     events, and could fail on exactly the day it is needed.
5. **Tiny always-on.** No automation and no dependency on the spot instance. The staging
   instance keeps its Elastic IP for itself.

## Recommendation

**Option 5, on Lightsail.**
- About $5 a month in the maintainer's own account, independent of Hasadna.
- Its static IP is the one to register with the Ministry.
- It writes to its own bucket, and the Hasadna node fills gaps from it. Snapshot keys are
  per minute, so a minute both requesters wrote is the same file twice, not a duplicate row.

When asking the Ministry, ask for **two** addresses. A replacement then needs no second
round with them.

Not decided yet:
- where the second bucket lives;
- how `ingest/` reads from two sources: a second listing, or a merge into one prefix.
