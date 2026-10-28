# Create the whole two-region stack and record how long it took.
param([switch]$PlanOnly)
. "$PSScriptRoot\_common.ps1"

Initialize-Tf
if ($PlanOnly) { Invoke-Tf @("plan", "-input=false"); return }

$sw = [Diagnostics.Stopwatch]::StartNew()
Invoke-Tf @("apply", "-input=false", "-auto-approve")
$sw.Stop()
Write-Timing "up" $sw.Elapsed.TotalSeconds

"Stack up in {0:n0}s." -f $sw.Elapsed.TotalSeconds
"Front Door URL: " + (terraform "-chdir=$Root\infra\stack" output -raw frontdoor_url)
"It bills until you run scripts\down.ps1."
