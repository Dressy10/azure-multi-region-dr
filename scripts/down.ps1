# Destroy the whole stack, then PROVE it is gone. A destroy only counts if every stack resource
# group no longer exists (a provider crash once left an empty group and out-of-sync state).
. "$PSScriptRoot\_common.ps1"

Initialize-Tf
$sw = [Diagnostics.Stopwatch]::StartNew()
Invoke-Tf @("destroy", "-input=false", "-auto-approve")
$sw.Stop()
Write-Timing "down" $sw.Elapsed.TotalSeconds

$left = @($StackRgs | Where-Object { (az group exists -n $_) -eq "true" })
if ($left.Count) {
    throw "Destroy finished but these resource groups still exist: $($left -join ', '). Re-run down.ps1."
}
"Stack destroyed in {0:n0}s. Verified: no stack resource groups remain." -f $sw.Elapsed.TotalSeconds
