# Create the whole two-region stack and record how long it took.
#   -CosmosOnly : create just the resource groups and the Cosmos account/database/container (for data
#                 drills). Skips Front Door and the Container Apps, which are slower and cost more.
param([switch]$PlanOnly, [switch]$CosmosOnly)
. "$PSScriptRoot\_common.ps1"

Initialize-Tf
$targets = if ($CosmosOnly) { @("-target=azurerm_cosmosdb_sql_container.ledger") } else { @() }
if ($PlanOnly) { Invoke-Tf (@("plan", "-input=false") + $targets); return }

$sw = [Diagnostics.Stopwatch]::StartNew()
Invoke-Tf (@("apply", "-input=false", "-auto-approve") + $targets)
$sw.Stop()
Write-Timing $(if ($CosmosOnly) { "up-cosmos-only" } else { "up" }) $sw.Elapsed.TotalSeconds

"Stack up in {0:n0}s." -f $sw.Elapsed.TotalSeconds
if (-not $CosmosOnly) { "Front Door URL: " + (terraform "-chdir=$Root\infra\stack" output -raw frontdoor_url) }
"It bills until you run scripts\down.ps1."
