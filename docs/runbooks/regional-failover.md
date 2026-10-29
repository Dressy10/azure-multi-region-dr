# Runbook: fail over to the DR region

Use when the primary region (UK South) is unavailable or unsafe to use. Everything below is based on the measured drill in `docs/drills/2026-10-29-failover-drill.md`. Limits of those measurements apply.

## 0. Decide it is a regional problem
- Check Azure status for the region and Front Door health. If only one app instance is failing, restart the app first. Failing over a region is disruptive and so is failing back.

## 1. Traffic (automatic, usually nothing to do)
Front Door probes every origin's `/healthz` every 10 s and marks an origin unhealthy after 3 of the last 4 probes fail. Traffic then moves to the priority 2 origin (France Central) on its own. In the drill this took about 20 s.
- Confirm: `curl https://<frontdoor-host>/version` returns `dr-francecentral`.
- Front Door cannot be created during an incident. A new endpoint took about 18 minutes to start serving, so it must already exist.

## 2. Data (needs a decision and a command)
Cosmos has automatic failover on, but a regional outage that service health does not declare may not trigger it. To fail over deliberately:
```powershell
az cosmosdb failover-priority-change -n cosmos-drproj-76256c -g rg-drproj-global --failover-policies francecentral=0 uksouth=1
```
- Expect the command to take about 70 s.
- Expect clients without write-region discovery to see HTTP 403 with sub-status 3 for roughly 77 to 82 s, continuing for about 30 s after the command returns. Clients on the official SDK with endpoint discovery should recover faster (not yet measured here).
- Confirm writes with a test document and check the write region: `az cosmosdb show -n cosmos-drproj-76256c -g rg-drproj-global --query "locations[].{r:locationName,p:failoverPriority}"`.

## 3. Failback
1. Only fail back when the primary region is confirmed healthy and stable.
2. Traffic: Front Door moves it back by itself once the primary is healthy (in the drill, 45.8 s after the primary came back, with no failed requests).
3. Data: run the same command with the priorities swapped. Expect the same disruption as step 2.

## 4. Afterwards
- Record times, failed requests and any lost writes. Compare with `docs/drills/`.
- Write a blameless postmortem for any real use.

## Known gaps
- Unplanned regional data loss (RPO) has not been measured. A planned failover is designed to lose nothing, and in the drill none of the 296 acknowledged writes was lost.
- The drills simulated an application outage, not a whole-region failure.
