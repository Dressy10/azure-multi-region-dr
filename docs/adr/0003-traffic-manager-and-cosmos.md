# ADR 0003: Traffic Manager for ingress, Cosmos DB for data

Status: accepted (revisit after the first cost measurement)

## Decision
- **Ingress:** Azure Traffic Manager with priority routing and HTTP health probes.
- **Data:** one Cosmos DB account (NoSQL API) with two regions and automatic failover.
- **Compute:** Azure Container Apps, scale to zero.

## Why
- Traffic Manager is DNS-based and costs cents. Failover time is probe interval plus failure threshold plus DNS TTL, all of which can be tuned and measured.
- Cosmos DB replicates across regions as a platform feature and supports automatic and manual failover, which makes the failover mechanism easy to drill and the RPO and RTO easy to measure.
- Container Apps at scale zero cost almost nothing when idle, which fits a warm standby on a small budget.

## Rejected
- **Azure Front Door:** faster, connection-level failover and a nicer edge, but a base fee of about $35 a month even when idle. Kept as an upgrade path if DNS failover time proves too slow.
- **PostgreSQL Flexible Server with a cross-region replica:** familiar, but as I understand it read replicas are not available on the Burstable tier, so the cheap option is lost. To be re-checked against current pricing before ruling out for good.
- **Azure SQL failover groups:** good product, higher idle cost, less transparent for drills.
- **AKS in both regions:** reuses earlier work but a cluster per region has a fixed hourly cost that works against the goal.

## Consequences
- DNS failover is bounded by client and resolver caching of the TTL, so measured RTO will include that, and some clients will take longer.
- Cosmos consistency level is a direct RPO trade-off. It will be chosen and justified when the stack is built, then verified by a drill that writes continuously during the failure.
