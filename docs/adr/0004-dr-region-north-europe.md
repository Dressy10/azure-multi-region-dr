# ADR 0004: DR region moved from UK West to North Europe

Status: superseded by the outcome below. North Europe was tried and refused as well; the data layer is an open decision. Amends ADR 0001.

## Context
ADR 0001 chose UK South (primary) and UK West (DR), an Azure region pair. The first real `terraform apply` failed creating the Cosmos DB account's second region:

> Sorry, we are currently experiencing high demand in UK West region, and cannot fulfill your request at this time. To request region access for your subscription, please follow this link...

Before that apply, the Cosmos locations API reported UK West as `Online` and not residency-restricted. That field is a general availability status. It says nothing about whether this subscription has been granted capacity. A check like it should not be treated as proof of capacity.

## Decision
Use North Europe (Dublin) as the DR region.
- It is the nearest alternative to UK South, so cross-region latency stays low.
- It supports availability zones, which UK West does not.
- Both Cosmos DB and Container Apps list it as available.

West Europe is the fallback if North Europe hits the same capacity wall.

## Rejected
- **Requesting UK West access** (support ticket): keeps the Azure pair, but the wait is uncertain and it blocks the whole project meanwhile. Reasonable to do in parallel and revisit later.
- **Replacing Cosmos DB** with another data tier: would abandon the part of the design that makes failover easy to drill and measure.

## Consequences
- The DR region is no longer an Azure paired region, so Azure's practice of sequencing platform maintenance across a pair no longer protects us. The two regions are still separate Azure regions, so a regional outage in one does not take down the other.
- Residency: data now replicates to Ireland. That is inside the EU/EEA but outside the UK. For a real UK-regulated workload this needs a data-protection decision.
- The landing-zone policy's allowed-regions list (audit-only) does not include North Europe, so the DR resources are flagged non-compliant until that list is updated.
- The lesson for the project: capacity must be proven by creating the resource, not inferred from an availability listing. Phase 3 drills should always start with a real apply.

## Outcome (added after the second apply)
North Europe failed in the same way as UK West. Adding it to the Cosmos account returned:

> Sorry, we are currently experiencing high demand in North Europe region, and cannot fulfill your request at this time. To request region access for your subscription, please follow this link...

Two different regions refusing the same service suggests a limit on this subscription rather than bad luck in one region. That is an inference: Azure's message only says region access must be requested, and I have not confirmed the cause with Microsoft. West Europe may behave the same, but was not tried.

What was still proven before the stack was destroyed:
- Both Container Apps (UK South primary, and the DR app) served `/healthz` and `/version` correctly, each reporting its own region.
- Front Door's health probes reached both origins (over 1,000 successful probes each) with zero errors.
- The Front Door default endpoint nevertheless returned an empty-body 404 for client requests for more than 25 minutes, with the route showing `Succeeded` but `deploymentStatus: NotStarted`. The 404 was generated at the Front Door edge (the apps recorded zero 4xx). Disabling and re-enabling the route did not change it. The cause was not found and needs a fresh apply to investigate.

Open decisions: request Cosmos region access (https://aka.ms/cosmosdbquota), use a data tier that does not need that grant, or prove compute and traffic failover first with the data layer simulated.

Process lesson: an interrupted `terraform apply` kept replacing resources after the stack was deleted by hand, recreating the DR resource group in North Europe. Never delete resources out from under a running apply without stopping it first, and always re-verify afterwards.

## Resolution: capacity probe, then France Central
Instead of guessing a third region, six regions were probed by creating an empty Cosmos DB account in each (no throughput, so no cost) and recording whether Azure accepted it. UK West and North Europe were included as controls, since both were already known to be refused.

| Region | Result |
|---|---|
| UK West | refused (control, as expected) |
| North Europe | refused (control, as expected) |
| West Europe | refused |
| France Central | accepted |
| Germany West Central | accepted |
| Sweden Central | accepted |

The controls failed as predicted, which is what makes the other results believable: the probe measures the same limit as the real multi-region apply. A probe account is a single-region creation, so it is a good but not perfect proxy for adding a replica region; the real apply is the final test.

Decision: **France Central (Paris)**, the closest accepted region to UK South. Container Apps lists it as available. It is not an Azure paired region, and data now replicates to France (inside the EU, outside the UK), which needs a data-protection decision for any real UK-regulated workload. Germany West Central and Sweden Central are the fallbacks.

## Update: the Front Door 404 was slow propagation after all
The earlier note that the 404 "was not propagation" was wrong. On the France Central stack the same symptom appeared and then cleared by itself about 18 minutes after the apply finished: the edge's 404 for this endpoint was byte-identical to its 404 for a hostname it has never heard of (same 266,389-byte page), which fits "this edge node does not have the config yet", and over about 20 seconds requests flipped from 404 to 200 and then stayed at 200 (40 of 40). The first stack was destroyed after roughly 25 minutes, which probably just was not long enough. `deploymentStatus: NotStarted` stayed on the route and endpoint throughout, including while the endpoint was serving, so that field is not a reliable readiness signal and should not be used to gate anything.
