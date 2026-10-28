# ADR 0001: Warm standby across a region pair

Status: accepted

## Context
The goal is a credible disaster recovery design that does not carry a large idle cost. The usual DR tiers trade recovery speed for cost:

| Tier | Recovery | Idle cost |
|---|---|---|
| Backup and restore | hours | lowest |
| Pilot light (data replicated, compute off) | tens of minutes | low |
| Warm standby (data replicated, compute scaled down but deployed) | minutes | moderate |
| Active-active | near zero | highest, and hardest to get right |

## Decision
Warm standby. Data is replicated continuously. Compute is deployed in both regions, and the DR region's Container App scales to zero until needed, so it is warm without costing much. Targets: RTO 5 minutes or less, RPO under 1 minute.

Regions are UK South (primary) and UK West (DR), an Azure region pair, so platform maintenance is sequenced across them and both sit inside the existing allowed-regions policy.

## Rejected
- Backup and restore: RTO in hours cannot be honestly called disaster recovery for a payments-style service.
- Active-active: needs conflict handling and multi-writer data design that would dominate the project and hide the DR lessons.
- A pair outside the UK: more latency and a policy change for no learning gain.

## Consequences
- Failover requires a human or automation to promote the DR region. Automatic failover is limited to what the data service and DNS health probes do on their own.
- The DR compute path is only exercised by drills, so drills must be routine and measured.
