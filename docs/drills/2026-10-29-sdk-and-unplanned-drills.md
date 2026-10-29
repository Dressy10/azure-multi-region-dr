# Cosmos DB drills with the official SDK, and a simulated unplanned outage (2026-10-29)

Status: complete. Follows `2026-10-29-failover-drill.md`, which measured a naive REST client and a planned failover. This round answers its two open questions: how much of the write failure window the official SDK removes, and what an unplanned outage does to acknowledged writes. Blameless: this is about the design and how it was measured.

## What was tested
A continuous writer (about 5 writes per second, each with a unique id) against a two-region account (UK South write region, France Central), with every acknowledgement logged. Afterwards every stored document was read back and compared with the acknowledged writes.

| Drill | Client | Consistency | Fault |
|---|---|---|---|
| A | official `azure-cosmos` SDK, preferred regions | Session | planned failover, then failback |
| B | same | Session | simulated regional outage: UK South taken offline with the service's `offlineRegion` API (two runs) |
| C | same | Strong | same simulated outage |

## Results

### A. SDK, planned failover and failback (790 writes)
| Measure | Result |
|---|---|
| Failed writes | 0 |
| Acknowledged writes missing | 0 (790 acknowledged, 790 stored) |
| Stall on failover | one write took 6.0 s, 22.6 s after the command started |
| Stall on failback | one write took 7.1 s, 21.0 s after the command started |
| Typical write | p50 160 ms |

Compared with the naive REST client in the same test (99 and 100 failed writes, roughly 77 to 82 s of 403 sub-status 3 on each event), the SDK removes the failures: it stalls and retries one write for a few seconds and carries on. The failover command itself still takes about 70 s.

### B. SDK, Session consistency, simulated unplanned outage
| Measure | Run 1 (cut short) | Run 2 (full 150 s observation) |
|---|---|---|
| Writes attempted and acknowledged | 221 | 918 |
| Documents actually stored | 183 | 154 |
| **Acknowledged writes missing** | **38** | **764** (83% of the run) |
| Client-visible errors | none | none |
| Last write that replicated, after the outage call | 14.2 s | 19.7 s |
| Service reports France Central as write region | not recorded | 43.3 s after the call |
| Writes acknowledged after that switch | not recorded | 652, none of them stored |

Both runs show the same shape. For about 15 to 20 seconds after the outage call everything replicated normally. After that every write was still acknowledged with HTTP 201, but none reached France Central. In run 2 this carried on for the entire observation, long after the service itself had promoted France Central. The SDK never saw an error, so it never moved away from UK South. The misses are one contiguous block (run 1: seq 184 to 221; run 2: seq 155 to 918). A re-read minutes later showed the same count, so this is not replication lag.

### C. SDK, Strong consistency, same simulated outage
| Measure | Result |
|---|---|
| Writes acknowledged and stored | 162 and 162 |
| **Acknowledged writes missing** | **0** |
| Writes during the outage | blocked: the first write after the cut (started 16.7 s after the outage call) hung for 122.9 s and failed with HTTP 503 (sub-status 21006); the next write did the same |
| Service write region switch | within 40.4 s of the call (first poll that showed it) |
| First successful write afterwards | between 10:51:13 and 10:51:45 UTC (a single write succeeded in 2.0 s at 10:51:45) |
| Write unavailability | about 4.1 to 4.6 minutes, then it recovered without any action |

Strong lost nothing, but nothing could be written for roughly 4.5 minutes, which is only just inside the 5-minute RTO target.

## What this means
- **Session is not safe for a payments-style service here.** It chooses availability: the client keeps getting acknowledgements while replication is cut, and those writes are silently lost from the surviving region's point of view. Acknowledged does not mean durable across regions.
- **Strong chooses correctness: it refuses to acknowledge what it cannot replicate**, at the price of a write outage of minutes. With only two regions there is no way to keep both.
- **Neither setting delivered RPO under 1 minute and RTO under 5 minutes together** in this simulated partition. Session met the RTO (no visible outage) and failed the RPO badly; Strong met the RPO (zero) and only just met the RTO.
- A design that must keep writing and lose nothing needs more than a consistency setting, for example a third region, Bounded Staleness (RPO bounded by its staleness window), or application-level idempotent writes with a replayable log. None of those was tested.
- The idempotent `record(ref)` in `app/ledger_dr/` means a client that does notice a failure can retry safely. It does not help when the client is never told about the failure, which is exactly the Session case.

## Limits of these drills
- **The outage is simulated.** `offlineRegion` leaves the "offline" region answering requests, so run B and C model a region that is alive but cut off from replication. A region that is truly dead would make writes to it fail or time out, so the real pattern could differ (and the SDK would probably fail over sooner). The "acknowledged by the old region" explanation is my inference from "acknowledged, but absent from France Central"; it was not observed directly.
- **Possibly recoverable data.** Cosmos documents a conflicts feed for writes the former write region held back, available once that region returns. The service rejected the call to bring the region back (`OnlineRegion capability not enabled`), so this could not be tested. The missing writes may be recoverable in a real incident.
- **One run per configuration** for A and C, two for B. Indicative only.
- **Cosmos create and delete times vary a lot**: creating the account took 6 to 7 minutes twice and 50 minutes once; deleting took 18 to 20 minutes.

## Mistakes found while measuring
- The drill summary first reported the same 7.1 s stall for both the failover and the failback, because the first event's window ran into the second. Found by reading the raw log; fixed.
- The Strong run's summary said "1 failed write, longest gap 0.6 s", which hid a 123 s stall: a write is logged at its start time and only when it returns, and the gap figure only counted acknowledged writes. Found by noticing the log held only 163 writes. The script now also reports the slowest write of any outcome.
- The first Session unplanned run ended when the restore call failed, cutting the observation to about 8 s and understating the loss by a factor of 20. Re-run with a fixed observation window.
- One drill attempt failed at start because a fixed 30 s wait for the writer was too short. The script now waits for acknowledged writes.
- I labelled one check "about 20 minutes after the cut" when it was about 5. Corrected before use.

## Action items
| # | Action | Status |
|---|---|---|
| 1 | Pick the consistency level deliberately: ADR 0005 chooses Strong for this payments-style design and records the trade-off | done |
| 2 | Test whether a third region lets Strong keep accepting writes during a regional outage | open |
| 3 | Test Bounded Staleness and quantify its RPO bound | open |
| 4 | Test the former write region's conflicts feed once the region can be brought back (needs an account where `onlineRegion` is enabled) | open |
| 5 | Repeat the outage with a harder fault that makes the region unreachable, not just cut from replication | open |
| 6 | Repeat each drill several times for something closer to a distribution | open |
