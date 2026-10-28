# Multi-region disaster recovery on Azure, built to be destroyed

A warm-standby DR design across two paired Azure regions that is **fully created by `terraform apply` and fully removed by `terraform destroy`**. Disaster recovery is usually expensive because a second region sits idle all year. Here the whole stack is disposable: you stand it up, run a failover drill, record the measured RPO and RTO, and destroy it. Only a tiny bootstrap (Terraform state and CI identities) stays.

## Status

| Phase | Scope | State |
|---|---|---|
| 0 | Repo, design, ADRs, bootstrap (state + OIDC identities), CI checks | in progress |
| 1 | Two-region stack: Cosmos DB, Container Apps, Traffic Manager, monitoring | not started |
| 2 | Sample payments-style service that writes through the stack | not started |
| 3 | Automated failover and failback drills with measured RPO and RTO | not started |
| 4 | Cost proof: priced run, idle cost, destroy/recreate timings, runbooks, postmortem | not started |

No results are claimed yet. Every number below is a target or an estimate, and will be replaced by measurements.

## Design

```
                 users
                   |
          Traffic Manager (DNS, priority routing, health probes)
              /                         \
   UK South (primary)             UK West (DR, warm standby)
   Container Apps (min 1)         Container Apps (scale to zero)
          \                         /
        Cosmos DB, two regions, automatic failover
                   |
        Log Analytics, daily ingestion cap
```

- **Regions:** UK South (primary) and UK West (DR), an Azure region pair. Both are already in the allowed-regions policy of my landing zone.
- **Traffic:** Traffic Manager with priority routing and HTTP health probes. DNS-based, so failover time is bounded by probe interval plus DNS TTL.
- **Compute:** Container Apps in both regions, scale to zero. Idle cost is close to nothing.
- **Data:** one Cosmos DB account replicated to both regions with automatic failover. Failover is service-managed and can be triggered on demand for drills.
- **No secrets:** workloads use managed identity, and CI uses OIDC. Nothing long-lived is stored.

Rejected alternatives and reasons are in `docs/adr/`.

## What "built to be destroyed" means

| Survives `terraform destroy` | Destroyed |
|---|---|
| Terraform state (GRS storage account, versioned) | both regional stacks |
| GitHub OIDC identities and role assignments | Cosmos DB, Container Apps, Traffic Manager |
| This repo, ADRs, runbooks, drill results | monitoring workspaces |

Recreating is one command from the pipeline or a laptop. Nothing is configured by hand, so there is nothing to lose.

## Cost model (estimates, to be verified)

These are my own estimates from list prices, not billed amounts, and must be checked in the Azure Pricing Calculator.

| Item | Idle (stack destroyed) | Drill (stack up) |
|---|---|---|
| Bootstrap: state storage | cents per month | same |
| Cosmos DB, 400 RU/s in two regions | 0 | roughly $0.07 per hour |
| Container Apps | 0 | near 0 (scale to zero; free monthly grant) |
| Traffic Manager | 0 | cents |
| Log Analytics (capped) | 0 | cents |

If left running all month the stack would cost on the order of $50. A two-hour drill should cost well under $1. The project will report the real figure from the bill.

## Targets (not yet measured)

| Objective | Target |
|---|---|
| RTO (regional failure to traffic served from DR) | 5 minutes or less |
| RPO (data loss at failover) | under 1 minute for acknowledged writes |
| Recreate from nothing | to be measured |

## Layout

- `infra/bootstrap/`: state storage and OIDC identities, applied once by hand
- `docs/adr/`: architecture decision records

## Bootstrap

```powershell
az login
gh api repos/<owner>/<repo>/actions/oidc/customization/sub   # copy sub_claim_prefix
cd infra/bootstrap
terraform init
terraform apply -var subscription_id=<sub> -var github_subject_prefix=<sub_claim_prefix>
```

Then store the outputs as GitHub repo variables: `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_PLAN_CLIENT_ID`, `AZURE_APPLY_CLIENT_ID`, `TFSTATE_RG`, `TFSTATE_SA`.
