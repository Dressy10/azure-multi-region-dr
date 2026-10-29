# ADR 0005: Strong consistency for the ledger

Status: accepted, with caveats below. Amends ADR 0003 (which started with Session and promised to measure the RPO it implies).

## Context
ADR 0003 chose Session consistency as a starting point and said the resulting RPO would be measured, not assumed. It has now been measured (see `docs/drills/2026-10-29-sdk-and-unplanned-drills.md`) in a simulated unplanned regional outage with the official SDK:

| | Session | Strong |
|---|---|---|
| Acknowledged writes lost | 764 of 918 over 164 s (83%); the first, shorter run lost 38 | 0 |
| What the client saw | nothing: every write was acknowledged | writes blocked for about 4.1 to 4.6 minutes, then 503s, then it recovered by itself |

## Decision
Use **Strong** consistency (`cosmos_consistency` defaults to `Strong` in `infra/stack`). For a payments-style ledger, an acknowledged write that silently vanishes is worse than a write that is refused: a refused write can be retried (the store is idempotent by `ref`), a lost acknowledged write cannot be noticed.

## Rejected
- **Session:** best availability, but acknowledged writes were lost in bulk, with no error for the client to react to.
- **Eventual and Consistent Prefix:** weaker than Session, so no better for this.
- **Bounded Staleness:** would put a bound on the loss (its staleness window), which is better than Session's unbounded loss, but it was not tested, so its numbers are unknown. Worth testing next.

## Consequences and caveats
- **Write outage of minutes in a regional failure.** About 4.1 to 4.6 minutes was measured, which is only just inside the 5-minute RTO target. This was measured with two regions only. A third region may keep writes available; that is untested.
- **Cost and latency were not measured.** Strong consistency is expected to cost more request units on reads and to make writes wait for cross-region commit, but the drills ran a small synthetic load and did not quantify either.
- **The outage was simulated** with the service's offline-region API, which leaves the cut-off region answering requests. A genuinely dead region could behave differently. See the limits section of the drill write-up.
- **Not yet verified end to end:** the full stack (Front Door and Container Apps) has not been run with Strong consistency. The data layer drills were run on the Cosmos-only stack.
- The decision should be revisited after the open drills (third region, Bounded Staleness, a harder fault).
