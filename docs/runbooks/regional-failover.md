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

## 5. If a region is cut off from replication but still answering (the dangerous case)
The simulated-outage drills (`docs/drills/2026-10-29-sdk-and-unplanned-drills.md`) showed a failure with no error:
- Under **Session** consistency the cut-off region kept acknowledging writes that never reached the other region. 764 of 918 acknowledged writes were missing afterwards, and the SDK client never saw an error, even after the service had promoted the DR region.
- Under **Strong** consistency nothing was lost, but no write succeeded for about 4.1 to 4.6 minutes.
So: the project uses Strong (ADR 0005). Expect a write outage of a few minutes during a regional failure rather than silent loss. Do not read "the write succeeded" as "the write is safe" unless the account is on Strong.
- After such an incident, compare the application's own record of acknowledged writes with what the surviving region holds before declaring the failover complete.
- Check the former write region's conflicts feed once it is reachable again. Cosmos documents it as the place unreplicated writes can be recovered from. This was not tested here.

## Known gaps
- RPO was measured only in simulated outages. Planned failover lost nothing (790 of 790 writes stored). A simulated outage under Session lost most writes after the cut; under Strong it lost none.
- The drills simulated an application outage and a region cut off from replication, not a whole-region failure. A genuinely dead region could behave differently.
- The service refused to bring a simulated-offline region back (`OnlineRegion capability not enabled`), so every unplanned-outage drill needs a fresh account: about 20 minutes to destroy, and 6 to 50 minutes to recreate in this subscription.
