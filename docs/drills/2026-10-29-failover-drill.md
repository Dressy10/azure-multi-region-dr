# Failover drill, 2026-10-29

Status: complete. Type: planned exercise on the disposable stack (UK South primary, France Central DR). No customer impact (synthetic traffic only). Blameless: this is about the system and how it was measured.

## What was tested
Two drills against the live two-region stack, each measured by a client rather than read from Azure's status fields.

| Drill | Fault | Client |
|---|---|---|
| Traffic | The primary Container App's revision was deactivated (the app is gone, the region and ingress remain) | A probe requesting `/version` through Front Door about twice a second |
| Data | Cosmos DB failed over to France Central and back (`failover-priority-change`) | A REST writer doing about 5 writes per second, logging every acknowledgement |

Expectations going in (only the expected zero loss for a planned failover was stated in advance in the session; the rest were informal and are written down here afterwards, so treat them as weaker than a pre-registered hypothesis):
1. Front Door fails over to the DR region within the 5-minute RTO target.
2. Failback happens without failed requests.
3. A planned Cosmos failover loses no acknowledged writes.
4. Writes keep working through the failover with at most a short blip.

## Results

### Traffic failover (raw log: `docs/metrics/drill-traffic-20261029-094009.csv`)
| Measure | Result |
|---|---|
| Failed requests | 39, all HTTP 404 from the stopped app's ingress |
| First failed request to first answer from the DR region | about 20 s (08:41:02.9 to 08:41:22.98 UTC) |
| After that | every request answered by `dr-francecentral` |
| Failback: primary re-activated to serving again | 45.8 s, with zero failed requests (traffic stayed on DR until the primary was healthy) |

Hypotheses 1 and 2: confirmed. Detection time is consistent with the Front Door probe settings (probe every 10 s, 3 of the last 4 must succeed).

### Data failover and failback (raw log: `docs/metrics/drill-cosmos-20261029-095322.csv`)
| Measure | Failover to DR | Failback to primary |
|---|---|---|
| `failover-priority-change` command duration | 71 s | 70 s |
| First failed write after command start | 22 s | 21 s |
| Last failed write after command start | 99 s | 103 s |
| Write outage (first to last failed write) | about 77 s | about 82 s |
| Failed writes | 99 | 100 |
| Failure type | all HTTP 403, sub-status 3 (`WriteForbidden`) | same |

Of 497 writes attempted, 296 were acknowledged, 199 were rejected, and 298 documents are stored. Zero acknowledged writes are missing. None of the rejected writes was stored. The 2 extra stored documents (seq 449 and 479) are not a discrepancy: their rows were never logged, because the writer's file append collided with the orchestrator reading the CSV. That bug is fixed.

Hypothesis 3: confirmed for a planned failover. Hypothesis 4: **not** confirmed as stated: writes failed for roughly 77 to 82 s, not a short blip.

## What this means
- The 403 sub-status 3 is how Cosmos reports "this region is no longer the write region". The writer here is a bare REST client with no write-region discovery. The last failure came about 28 to 33 s after the failover command had returned, so a client that does not refresh the account's region list keeps hitting the old write region. The official SDKs handle this themselves, so the real figure for an SDK-based service is expected to be lower. That is untested here and is the first thing Phase 2 should check.
- Traffic failover (about 20 s) is far inside the 5-minute RTO target. The data path is the slower one: about 70 s of command plus the client's lag.
- Failback through Front Door is clean because Front Door will not move traffic back until the primary is healthy.

## Limits of these drills
- The traffic fault is an application outage in UK South, not a whole Azure region failing. A real regional outage may behave differently, including taking longer to detect.
- The Cosmos failover is planned (graceful). It is designed to lose nothing, so the zero-loss result says nothing about an unplanned regional outage. Measuring that needs a forced failover, which was not attempted. RPO for an unplanned outage is therefore still unmeasured.
- One run of the traffic drill, two of the Cosmos drill, one client, one machine. Indicative only.
- Client latency in the traffic log (p50 about 417 ms) includes the path from my machine and is not a service figure.

## Mistakes found while measuring
- The traffic script first measured from when the fault command returned, but the app was already down while it ran. That dropped the first 2 failures and printed a misleading "0.2 s to first failure". Found by recomputing from the raw rows. Fixed.
- The first Cosmos drill run died at its read-back step (a content-type bug, now fixed). Its raw log still showed the same failure pattern, and the second run was done to get the complete result.
- The writer silently dropped two log rows through file contention. Found because the stored count did not match the log. Fixed with a retry.

## Action items
| # | Action | Status |
|---|---|---|
| 1 | Build the Phase 2 service on the Cosmos SDK with preferred regions and endpoint discovery, and repeat the data drill to measure how much of the 77 to 82 s an SDK removes | open |
| 2 | Run a forced (unplanned) Cosmos failover to measure real RPO, if the service allows it on this subscription | open |
| 3 | Repeat the traffic drill with a harder fault, such as blocking the primary's ingress network path, to be closer to a regional failure | open |
| 4 | Decide whether to shorten the Front Door probe interval below 10 s to cut detection time, weighing probe traffic | open |
| 5 | Remember that Front Door took about 18 minutes to start serving after creation, so it must exist before a disaster; it cannot be created during one | noted in ADR 0003 |
