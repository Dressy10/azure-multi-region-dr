# Traffic failover drill. Takes the PRIMARY app offline (deactivates its revision: the app is gone but
# the region and ingress remain), watches what a client sees through Front Door, then restores it.
# LIMIT: this simulates an application outage in the primary region, not a whole Azure region failing.
# Needs the stack up and Front Door serving. Writes docs/metrics/drill-traffic-*.csv/.json
param([string]$FrontDoorHost = "fde-drproj-76256c-dvf4d0gffxf5cbar.z01.azurefd.net")
$ErrorActionPreference = "Stop"
$root  = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$csv   = "$root\docs\metrics\drill-traffic-$stamp.csv"
$stop  = "$env:TEMP\drill-stop-$stamp"
New-Item -ItemType Directory -Force "$root\docs\metrics" | Out-Null
$events = [ordered]@{}
function Now-Ms { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
function Rows { Import-Csv $csv | ForEach-Object { [pscustomobject]@{ T = [long]$_.epoch_ms; Code = [int]$_.http_status; Body = $_.body.Trim() } } }

# 1. start the client probe
$probe = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile","-File","$PSScriptRoot\probe.ps1","-Url","https://$FrontDoorHost/version","-OutCsv",$csv,"-StopFile",$stop
Start-Sleep 25
$base = @(Rows)
"baseline: $($base.Count) requests, all primary? " + (@($base | Where-Object { $_.Code -eq 200 -and $_.Body -eq 'primary-uksouth' }).Count -eq $base.Count)
if (@($base | Where-Object { $_.Body -eq 'primary-uksouth' }).Count -lt 20) { New-Item $stop | Out-Null; throw "Baseline is not healthy and primary-served. Aborting." }

# 2. inject the fault
$revs = az containerapp revision list -n ca-drproj-primary -g rg-drproj-primary -o json | ConvertFrom-Json
$rev  = ($revs | Where-Object { $_.properties.active } | Select-Object -First 1).name
if (-not $rev) { New-Item $stop | Out-Null; throw "No active revision found on the primary app." }
"deactivating primary revision: $rev"
$events.fault_start_ms = Now-Ms   # the app starts failing WHILE this command runs, so measure from before it, not after
az containerapp revision deactivate -n ca-drproj-primary -g rg-drproj-primary --revision $rev | Out-Null
$events.fault_done_ms = Now-Ms
"fault injected at $([DateTimeOffset]::FromUnixTimeMilliseconds($events.fault_done_ms).ToString('HH:mm:ss')) UTC"

# 3. wait for 10 consecutive DR responses
$deadline = (Get-Date).AddSeconds(240); $drStable = $null
while ((Get-Date) -lt $deadline -and -not $drStable) {
    Start-Sleep 5
    $r = @(Rows | Where-Object { $_.T -ge $events.fault_done_ms })
    for ($i = 0; $i -le $r.Count - 10; $i++) {
        $w = $r[$i..($i+9)]
        if (@($w | Where-Object { $_.Code -eq 200 -and $_.Body -eq 'dr-francecentral' }).Count -eq 10) { $drStable = $w[0].T; break }
    }
}
$events.dr_stable_ms = $drStable
"DR serving stably: $(if($drStable){'yes'}else{'NO (timed out)'})"
Start-Sleep 20

# 4. restore the primary and wait for failback
az containerapp revision activate -n ca-drproj-primary -g rg-drproj-primary --revision $rev | Out-Null
$events.restore_done_ms = Now-Ms
"primary revision re-activated at $([DateTimeOffset]::FromUnixTimeMilliseconds($events.restore_done_ms).ToString('HH:mm:ss')) UTC"
$deadline = (Get-Date).AddSeconds(420); $pbStable = $null
while ((Get-Date) -lt $deadline -and -not $pbStable) {
    Start-Sleep 5
    $r = @(Rows | Where-Object { $_.T -ge $events.restore_done_ms })
    for ($i = 0; $i -le $r.Count - 10; $i++) {
        $w = $r[$i..($i+9)]
        if (@($w | Where-Object { $_.Code -eq 200 -and $_.Body -eq 'primary-uksouth' }).Count -eq 10) { $pbStable = $w[0].T; break }
    }
}
$events.primary_stable_ms = $pbStable
"failback to primary: $(if($pbStable){'yes'}else{'NO (timed out)'})"
Start-Sleep 10
New-Item $stop | Out-Null; Start-Sleep 2

# 5. compute from the raw rows
$all = @(Rows)
$afterFault = @($all | Where-Object { $_.T -ge $events.fault_start_ms })
$bad = @($afterFault | Where-Object { -not ($_.Code -eq 200 -and $_.Body -in 'primary-uksouth','dr-francecentral') })
$failOver = if ($drStable) { @($afterFault | Where-Object { $_.T -lt $drStable }) } else { $afterFault }
$failOverBad = @($failOver | Where-Object { -not ($_.Code -eq 200) })
$firstFail = ($failOverBad | Select-Object -First 1)
$lastFail  = ($failOverBad | Select-Object -Last 1)
$firstDr   = ($afterFault | Where-Object { $_.Code -eq 200 -and $_.Body -eq 'dr-francecentral' } | Select-Object -First 1)
$restoreRows = @($all | Where-Object { $_.T -ge $events.restore_done_ms })
$fbBad = @($restoreRows | Where-Object { $_.Code -ne 200 })
function Sec($a,$b) { if ($a -and $b) { [math]::Round(($b - $a) / 1000, 1) } else { $null } }
$res = [ordered]@{
    run                              = $stamp
    method                           = "client probe every ~500 ms through Front Door; fault = primary revision deactivated (app down, region up)"
    probe_requests_total             = $all.Count
    fault_command_seconds            = Sec $events.fault_start_ms $events.fault_done_ms
    seconds_fault_start_to_first_failure = Sec $events.fault_start_ms $firstFail.T
    seconds_first_failure_to_first_dr_answer = Sec $firstFail.T $firstDr.T
    seconds_first_failure_to_stable_dr = Sec $firstFail.T $drStable
    failed_requests_during_failover  = $failOverBad.Count
    seconds_of_failure_first_to_last = if ($firstFail) { [math]::Round((($lastFail.T - $firstFail.T) / 1000) + 0.5, 1) } else { 0 }
    failure_status_codes             = (($failOverBad | Group-Object Code | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ", ")
    seconds_restore_to_stable_primary = Sec $events.restore_done_ms $pbStable
    failed_requests_during_failback  = $fbBad.Count
    failback_status_codes            = (($fbBad | Group-Object Code | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ", ")
}
$res | ConvertTo-Json | Set-Content "$root\docs\metrics\drill-traffic-$stamp.json"
"`n=== RESULT ==="; $res.GetEnumerator() | ForEach-Object { "{0,-36} {1}" -f $_.Key,$_.Value }
"raw rows: $csv"
