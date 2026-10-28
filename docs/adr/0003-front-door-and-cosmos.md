# ADR 0003: Front Door for ingress, Cosmos DB for data

Status: accepted. Supersedes the first draft of this ADR, which chose Traffic Manager.

## Decision
- **Ingress:** Azure Front Door Standard with an origin group, priority routing (primary priority 1, DR priority 2) and HTTP health probes.
- **Data:** one Cosmos DB account (NoSQL API) replicated to both regions with automatic failover, Session consistency, Entra ID auth only.
- **Compute:** Azure Container Apps in each region.

## Why Front Door, and why the first draft was wrong
The first draft rejected Front Door because of its base fee of about $35 a month. That argument does not apply here: the whole stack is destroyed after each drill (ADR 0002), so Front Door is billed only for the hours it exists. Two further problems with Traffic Manager came up while designing the stack:
- Traffic Manager works by DNS: it answers with the origin's own hostname. Container Apps only route requests whose Host header they recognise, so a client that arrives via a Traffic Manager name would be rejected unless a custom domain were set up on each app. Front Door sets the origin host header itself and avoids that.
- Failover time with DNS includes resolver and client caching of the TTL, which is outside our control. Front Door fails over at the connection level using its own probes, so measured RTO depends mostly on probe settings we choose.

## Why Cosmos
It replicates across regions as a platform feature, supports automatic and manual failover, and makes drills and RPO measurement simple. Session consistency is a deliberate starting point; the RPO it implies is measured in Phase 3, not assumed.

## Rejected
- **Traffic Manager:** see above. Cheaper per hour, but adds a hostname problem and a TTL floor on RTO.
- **PostgreSQL Flexible Server with a cross-region replica:** familiar, but as I understand it read replicas are not available on the Burstable tier, so the cheap option is lost. To be re-checked against current pricing.
- **Azure SQL failover groups:** good product, higher idle cost, less transparent for drills.
- **AKS in both regions:** a cluster per region has a fixed hourly cost that works against the goal.

## Consequences
- Front Door's origin probes hit the DR origin too, so the DR Container App does not truly scale to zero while the stack is up. Idle compute is small but not zero, and this will be reported honestly in the cost measurement.
- Front Door adds a per-hour base cost while the stack exists, so the drill runtime should be kept short.
