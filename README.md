# Multi-region disaster recovery on Azure, built to be destroyed

A warm-standby DR design across two Azure regions that is **fully created by `terraform apply` and fully removed by `terraform destroy`**. Disaster recovery is usually expensive because a second region sits idle all year. Here the whole stack is disposable: you stand it up, run a failover drill, record the measured RPO and RTO, and destroy it. Only a tiny bootstrap (Terraform state and CI identities) stays.

## Status

| Phase | Scope | State |
|---|---|---|
| 0 | Repo, design, ADRs, bootstrap (state + OIDC identities), CI checks | done and applied, except the approval gate (see note) |
| 1 | Two-region stack: Cosmos DB, Container Apps, Front Door, monitoring | applied twice, blocked: Cosmos DB multi-region capacity refused in UK West and North Europe (see ADR 0004). Stack destroyed; data layer decision open |
| 2 | Sample payments-style service that writes through the stack | not started |
| 3 | Automated failover and failback drills with measured RPO and RTO | not started |
| 4 | Cost proof: priced run, idle cost, destroy/recreate timings, runbooks, postmortem | not started |

Approval gate: the `apply` identity is trusted only for a GitHub environment called `production`, which should require a manual reviewer. GitHub does not allow required reviewers on private repositories on the current plan, so that gate is not in place yet. Nothing uses the `apply` identity until a deploy workflow exists, and the gate must be in place before one does (either by making the repo public, where reviewers are free, or by upgrading the plan).

No results are claimed yet. Every number below is a target or an estimate, and will be replaced by measurements.

## Design

```
                 users
                   |
          Azure Front Door (priority routing, health probes)
              /                         \
   UK South (primary)             North Europe (DR, warm standby)
   Container Apps (min 1)         Container Apps (min 0, kept warm by probes)
          \                         /
        Cosmos DB, two regions, automatic failover
                   |
        Log Analytics, daily ingestion cap
```

- **Regions:** UK South (primary). The DR region is currently undecided. UK West (UK South's Azure pair) was the first choice and North Europe the second, and Cosmos DB refused to add either to my subscription for lack of granted capacity (ADR 0004). The Terraform default is North Europe, but it will not apply until the data layer is resolved. It is also outside the allowed-regions list of my landing-zone policy (audit-only).
- **Traffic:** Azure Front Door Standard with priority routing and HTTP health probes. Failover is at connection level, so measured RTO depends mainly on probe settings.
- **Compute:** Container Apps in both regions. The primary keeps one replica; the DR app is configured to scale to zero but Front Door's health probes keep it warm, so its idle cost is small, not zero.
- **Data:** one Cosmos DB account replicated to both regions with automatic failover. Failover is service-managed and can be triggered on demand for drills.
- **No secrets:** workloads use managed identity, and CI uses OIDC. Nothing long-lived is stored.

Rejected alternatives and reasons are in `docs/adr/`. ADR 0003 records a design change: Traffic Manager was the first choice and was replaced by Front Door.

## What "built to be destroyed" means

| Survives `terraform destroy` | Destroyed |
|---|---|
| Terraform state (GRS storage account, versioned) | both regional stacks |
| GitHub OIDC identities and role assignments | Cosmos DB, Container Apps, Front Door |
| This repo, ADRs, runbooks, drill results | monitoring workspaces |

Recreating is one command from the pipeline or a laptop. Nothing is configured by hand, so there is nothing to lose.

## Cost model (estimates, to be verified)

These are my own estimates from list prices, not billed amounts, and must be checked in the Azure Pricing Calculator.

| Item | Idle (stack destroyed) | Drill (stack up) |
|---|---|---|
| Bootstrap: state storage | cents per month | same |
| Cosmos DB, 400 RU/s in two regions | 0 | roughly $0.065 per hour |
| Front Door Standard | 0 | roughly $0.05 per hour (about $35 per month base fee, billed only while it exists) |
| Container Apps | 0 | cents (the DR app is kept warm by Front Door health probes) |
| Log Analytics (capped) | 0 | cents |

If left running all month the stack would cost on the order of $85 (about $0.12 per hour). A two-hour drill should cost well under $1. The project will report the real figure from the bill.

## Targets (not yet measured)

| Objective | Target |
|---|---|
| RTO (regional failure to traffic served from DR) | 5 minutes or less |
| RPO (data loss at failover) | under 1 minute for acknowledged writes |
| Recreate from nothing | to be measured |

## Layout

- `infra/bootstrap/`: state storage and OIDC identities, applied once by hand
- `infra/stack/`: the disposable two-region stack
- `scripts/up.ps1`, `scripts/down.ps1`: create the stack and time it; destroy it and verify it is gone
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
