# ADR 0002: Everything billable is disposable

Status: accepted

## Context
A DR environment that runs 24/7 is the main reason small teams skip DR. The aim here is to make the second region cost almost nothing when nobody is testing it.

## Decision
- Everything that costs money lives in a Terraform root module (`infra/stack`) with no manual steps, so `terraform destroy` removes it and `terraform apply` recreates it.
- Anything that must outlive a destroy lives in a separate bootstrap (`infra/bootstrap`): the Terraform state account and the CI identities. The state account is GRS so state survives a regional outage as well.
- Stack state is stored in the bootstrap's storage account under its own key, never inside the stack's own resource groups.
- Names that must be globally unique (for example the Front Door endpoint name and the Cosmos account) are derived deterministically from the subscription, so a recreated stack gets the same endpoints.
- A destroy is only considered successful if the stack's resource groups are gone, which the pipeline verifies.

## Rejected
- Leaving a minimal always-on DR region: cheaper than full active-passive, but still an ongoing bill and it hides recreation problems until a real disaster.
- Putting state in the stack: a destroy would delete the state needed to manage it.

## Consequences
- Recreate time becomes a real, measured part of the recovery story. It is not a target for failover (the stack exists during a drill) but it matters for restoring the DR posture afterwards.
- Data in the stack is lost on destroy. This project is about the failover mechanism, so drills use synthetic data only.
