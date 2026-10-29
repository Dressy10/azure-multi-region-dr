# Multi-region disaster recovery on Azure, built to be destroyed

A warm-standby DR design across two Azure regions that is **fully created by `terraform apply` and fully removed by `terraform destroy`**. Disaster recovery is usually expensive because a second region sits idle all year. Here the whole stack is disposable: you stand it up, run a failover drill, record the measured RPO and RTO, and destroy it. Only a tiny bootstrap (Terraform state and CI identities) stays.

## Status

| Phase | Scope | State |
|---|---|---|
| 0 | Repo, design, ADRs, bootstrap (state + OIDC identities), CI checks | done and applied, except the approval gate (see note) |
| 1 | Two-region stack: Cosmos DB, Container Apps, Front Door, monitoring | done and verified once (UK South primary, France Central DR; UK West and North Europe were refused, see ADR 0004) |
| 2 | Sample payments-style service that writes through the stack | not started |
| 3 | Automated failover and failback drills with measured RPO and RTO | done once for traffic and data (planned failover only); unplanned RPO not measured. See `docs/drills/` |
| 4 | Cost proof: priced run, idle cost, destroy/recreate timings, runbooks, postmortem | not started |

Approval gate: the `apply` identity is trusted only for a GitHub environment called `production`, which should require a manual reviewer. GitHub does not allow required reviewers on private repositories on the current plan, so that gate is not in place yet. Nothing uses the `apply` identity until a deploy workflow exists, and the gate must be in place before one does (either by making the repo public, where reviewers are free, or by upgrading the plan).

No results are claimed yet. Every number below is a target or an estimate, and will be replaced by measurements.

## Design

```
                 users
                   |
          Azure Front Door (priority routing, health probes)
              /                         \
   UK South (primary)             France Central (DR, warm standby)
   Container Apps (min 1)         Container Apps (min 0, kept warm by probes)
          \                         /
        Cosmos DB, two regions, automatic failover
                   |
        Log Analytics, daily ingestion cap
```

- **Regions:** UK South (primary) and France Central (DR, Paris). UK West (UK South's Azure pair) was the first choice, but Cosmos DB refused UK West, North Europe and West Europe for my subscription for lack of granted capacity. France Central was picked by probing real capacity in six regions, not from an availability list (ADR 0004). It is not an Azure paired region, and it is outside the allowed-regions list of my landing-zone policy (audit-only), so it shows as non-compliant until that list is updated.
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

## Measured so far (one run each, so indicative only)

| What | Result |
|---|---|
| `terraform apply` of the whole two-region stack (18 resources) | 493 s |
| Front Door serving requests after the apply finished | about 18 minutes (404 from the edge until the config rolled out; flapped between 404 and 200 for a short window, then 40 of 40 requests returned 200) |
| Cosmos DB | UK South (priority 0) and France Central (priority 1), automatic failover on, Entra ID auth only |
| Both origins | `/healthz` 200 and `/version` reports its own region |
| Via Front Door | `/version` returns `primary-uksouth` on every request (40 of 40 checked) |
| Traffic failover (primary app taken offline) | about 20 s from first failed request to the DR region answering; 39 failed requests (404) in that window |
| Traffic failback | 45.8 s after the primary came back, zero failed requests |
| Cosmos planned failover, data written continuously | 296 acknowledged writes, 0 lost, 0 of the 199 rejected writes stored |
| Cosmos write outage for a client without SDK region discovery | about 77 s (failover) and 82 s (failback), HTTP 403 sub-status 3; failover command itself about 70 s |
| Destroy and verify | 74 s for a stack that was already deleted; a full destroy has not been timed yet |

So the stack is created in about 8 minutes but is not reachable through Front Door for roughly 18 more. A recreate from nothing takes about 26 minutes before traffic flows.

## Targets against what was measured

| Objective | Target | Measured so far |
|---|---|---|
| RTO, traffic (failure to traffic served from DR) | 5 minutes or less | about 20 s for a simulated application outage in the primary region (not a whole-region failure) |
| RTO, data writes | 5 minutes or less | about 77 to 82 s of failed writes for a naive client; expected lower with the official SDK, not yet measured |
| RPO | under 1 minute for acknowledged writes | zero acknowledged writes lost in a PLANNED failover; unplanned regional RPO not measured |
| Recreate from nothing | to be measured | about 8 min to apply, then about 18 min before Front Door serves (about 26 min) |

## Layout

- `infra/bootstrap/`: state storage and OIDC identities, applied once by hand
- `infra/stack/`: the disposable two-region stack
- `scripts/up.ps1`, `scripts/down.ps1`: create the stack and time it; destroy it and verify it is gone
- `scripts/drill-traffic.ps1`, `scripts/drill-cosmos.ps1`: the failover drills, with client-side measurement
- `docs/drills/`, `docs/runbooks/`, `docs/metrics/`: drill write-ups, the failover runbook, and raw logs
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
