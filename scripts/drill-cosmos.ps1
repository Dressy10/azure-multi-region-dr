# Cosmos DB failover drill with a continuous writer, measured from the client side.
#
#   -Writer   naive : bare REST client, no write-region discovery (writer.ps1)
#             sdk   : official azure-cosmos Python SDK with preferred regions (writer_sdk.py)
#   -Scenario planned   : graceful failover to the DR region and back (failover-priority-change)
#             unplanned : takes the WRITE region offline with the service's offlineRegion API, which
#                         simulates a regional outage and relies on service-managed (automatic)
#                         failover, then brings it back. This is the closest test of real RPO here.
#
# After the run it reads back every stored document and compares with the acknowledged writes.
# LIMITS: a planned failover is designed to lose nothing; offlineRegion simulates an outage but is
# still an API call rather than a real failure. One run each. Indicative only.
param(
    [ValidateSet("naive", "sdk")][string]$Writer = "naive",
    [ValidateSet("planned", "unplanned")][string]$Scenario = "planned",
    [string]$Account = "cosmos-drproj-76256c",
    [string]$ResourceGroup = "rg-drproj-global",
    [string]$Primary = "uksouth",
    [string]$Dr = "francecentral"
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Net.Http
$root  = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$tag   = "$Writer-$Scenario"
$runId = "drill$stamp"
$csv   = "$root\docs\metrics\drill-cosmos-$tag-$stamp.csv"
$evf   = "$root\docs\metrics\drill-cosmos-$tag-$stamp.events.json"
$stop  = "$env:TEMP\cosmos-stop-$stamp"
New-Item -ItemType Directory -Force "$root\docs\metrics" | Out-Null
function Now-Ms { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
function Rows { Import-Csv $csv | ForEach-Object { [pscustomobject]@{ T = [long]$_.epoch_ms; Seq = [int]$_.seq; Code = [int]$_.http_status; Sub = $_.substatus; Ms = [int]$_.latency_ms; Detail = $_.detail } } }
$events = New-Object System.Collections.ArrayList

# Data-plane access: account keys are disabled, so the signed-in user needs a Cosmos data role.
$oid = az ad signed-in-user show --query id -o tsv
$existing = @(az cosmosdb sql role assignment list -a $Account -g $ResourceGroup -o json | ConvertFrom-Json | Where-Object { $_.principalId -eq $oid })
if (-not $existing.Count) {
    "granting the signed-in user Cosmos DB Built-in Data Contributor on this account (removed when the stack is destroyed)"
    az cosmosdb sql role assignment create -a $Account -g $ResourceGroup --role-definition-id 00000000-0000-0000-0000-000000000002 --principal-id $oid --scope "/" | Out-Null
    Start-Sleep 60
}

if ($Writer -eq "sdk") {
    $py = "$root\.venv\Scripts\python.exe"
    $wp = Start-Process $py -WindowStyle Hidden -PassThru -ArgumentList "-u","$PSScriptRoot\writer_sdk.py",$Account,$runId,$csv,$stop,"UK South,France Central"
} else {
    $wp = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile","-File","$PSScriptRoot\writer.ps1","-Account",$Account,"-RunId",$runId,"-OutCsv",$csv,"-StopFile",$stop
}
# Wait for the writer to be producing acknowledged writes, instead of a fixed sleep: Python import, the
# credential chain and the first connection take ~10 s, and a fixed 30 s once ran out (no CSV yet).
$deadline = (Get-Date).AddSeconds(150)
while ((Get-Date) -lt $deadline) {
    Start-Sleep 3
    if ((Test-Path $csv) -and @(Rows | Where-Object { $_.Code -eq 201 }).Count -ge 40) { break }
}
if (-not (Test-Path $csv)) { New-Item $stop | Out-Null; throw "The writer never created its log within 150 s (process alive: $(-not $wp.HasExited))." }
$base = @(Rows)
$okBase = @($base | Where-Object { $_.Code -eq 201 }).Count
"[$tag] baseline: $($base.Count) writes, $okBase acknowledged (201)"
if ($okBase -lt 20) { New-Item $stop | Out-Null; throw "Writer is not getting 201s (status codes: $((($base | Group-Object Code | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', ')); detail: $(($base | Where-Object { $_.Code -ne 201 } | Select-Object -First 1).Detail))." }

# Recovered = no non-201 in the last 15 s and the writer is producing writes again.
function Wait-Recovered([long]$since, [int]$maxSec = 420) {
    $deadline = (Get-Date).AddSeconds($maxSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep 5
        $r = @(Rows | Where-Object { $_.T -ge $since })
        $now = Now-Ms
        $recent = @($r | Where-Object { $_.T -ge ($now - 15000) })
        if ($recent.Count -ge 15 -and @($recent | Where-Object { $_.Code -ne 201 }).Count -eq 0) {
            $lastBad = $r | Where-Object { $_.Code -ne 201 } | Select-Object -Last 1
            return [pscustomobject]@{ Recovered = $true; LastFailMs = $(if ($lastBad) { $lastBad.T } else { $null }) }
        }
    }
    return [pscustomobject]@{ Recovered = $false; LastFailMs = $null }
}
function Save-Event($ev) { [void]$events.Add($ev); $events | ConvertTo-Json | Set-Content $evf }   # saved at once

function Failover($label, $first, $second) {
    Write-Host "--- $label : $first=0 $second=1"
    $s = Now-Ms
    az cosmosdb failover-priority-change -n $Account -g $ResourceGroup --failover-policies "$first=0" "$second=1" | Out-Null
    $e = Now-Ms
    Write-Host "    command took $([math]::Round(($e-$s)/1000))s; waiting for writes to recover"
    $rec = Wait-Recovered $s
    $ev = [pscustomobject]@{ Label = $label; StartMs = $s; EndMs = $e; Recovered = $rec.Recovered; LastFailMs = $rec.LastFailMs }
    Save-Event $ev; Write-Host "    recovered: $($rec.Recovered)"
    return $ev   # Write-Host above, so only the event object is returned
}
function Region-Action($label, $action, $region, [int]$maxSec) {
    Write-Host "--- $label : $action '$region'"
    $sub = az account show --query id -o tsv
    $bodyFile = "$env:TEMP\region-$action-$stamp.json"
    [IO.File]::WriteAllText($bodyFile, '{"region":"' + $region + '"}', (New-Object Text.UTF8Encoding($false)))
    $url = "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.DocumentDB/databaseAccounts/$Account/${action}?api-version=2024-05-15"
    $s = Now-Ms
    $out = (az rest --method post --url $url --body "@$bodyFile" 2>&1 | Out-String).Trim()
    $e = Now-Ms
    Write-Host "    api returned after $([math]::Round(($e-$s)/1000))s. response: $(if ($out.Length -gt 220) { $out.Substring(0,220) } else { $out })"
    if ($out -match "(?i)error|forbidden|not supported|BadRequest") { Save-Event ([pscustomobject]@{ Label = $label; StartMs = $s; EndMs = $e; Recovered = $false; LastFailMs = $null; ApiError = $out }); throw "$action was rejected: $out" }
    $rec = Wait-Recovered $s $maxSec
    $ev = [pscustomobject]@{ Label = $label; StartMs = $s; EndMs = $e; Recovered = $rec.Recovered; LastFailMs = $rec.LastFailMs }
    Save-Event $ev; Write-Host "    recovered: $($rec.Recovered)"
    return $ev
}

$aborted = $null
$obs = $null
try {
    if ($Scenario -eq "planned") {
        $f1 = Failover "failover to DR" $Dr $Primary
        $f2 = Failover "failback to primary" $Primary $Dr
    } else {
        $f1 = Region-Action "region outage: UK South offline" "offlineRegion" "UK South" 120
        # The 'offline' region may keep acknowledging writes for a while, so keep the writer running and
        # watch which region the service reports as the write region. (An earlier run stopped the writer
        # as soon as the restore call was rejected, which truncated the loss window.)
        Write-Host "--- observing for 150 s: which region is the write region, do writes keep being acknowledged?"
        $obs = New-Object System.Collections.ArrayList
        $until = (Get-Date).AddSeconds(150)
        while ((Get-Date) -lt $until) {
            $acc = az cosmosdb show -n $Account -g $ResourceGroup -o json | ConvertFrom-Json
            [void]$obs.Add([pscustomobject]@{ T = Now-Ms; WriteRegion = (@($acc.writeLocations | ForEach-Object { $_.locationName }) -join ","); Regions = (@($acc.locations | ForEach-Object { "$($_.locationName):$($_.provisioningState)" }) -join ",") })
            Start-Sleep 3
        }
        $obs | ConvertTo-Json | Set-Content "$root\docs\metrics\drill-cosmos-$tag-$stamp.writeregion.json"
        # Bringing the region back is not enabled on every account ("OnlineRegion capability not enabled"), so best effort only.
        try { $f2 = Region-Action "region restored: UK South online" "onlineRegion" "UK South" 600 }
        catch { $m = $_.Exception.Message; Write-Host "    onlineRegion unavailable: $($m.Substring(0, [Math]::Min(170, $m.Length)))"; $f2 = $null }
    }
} catch { $aborted = $_.Exception.Message; "ABORTED: $aborted" }
Start-Sleep 5
New-Item $stop | Out-Null; Start-Sleep 4
$all = @(Rows)

# Read back everything that was actually stored for this run.
$endpoint = "https://$Account.documents.azure.com"
$token = az account get-access-token --resource $endpoint --query accessToken -o tsv
$auth = [uri]::EscapeDataString("type=aad&ver=1.0&sig=$token")
$client = New-Object System.Net.Http.HttpClient
$stored = New-Object System.Collections.Generic.HashSet[int]
$cont = $null
do {
    $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, "$endpoint/dbs/drdb/colls/ledger/docs")
    $req.Headers.TryAddWithoutValidation("Authorization", $auth) | Out-Null
    $req.Headers.TryAddWithoutValidation("x-ms-date", [DateTime]::UtcNow.ToString("r").ToLowerInvariant()) | Out-Null
    $req.Headers.TryAddWithoutValidation("x-ms-version", "2018-12-31") | Out-Null
    $req.Headers.TryAddWithoutValidation("x-ms-documentdb-isquery", "True") | Out-Null
    $req.Headers.TryAddWithoutValidation("x-ms-documentdb-partitionkey", '["drill"]') | Out-Null
    $req.Headers.TryAddWithoutValidation("x-ms-max-item-count", "1000") | Out-Null
    if ($cont) { $req.Headers.TryAddWithoutValidation("x-ms-continuation", $cont) | Out-Null }
    $q = '{"query":"SELECT c.seq FROM c WHERE c.runId = @r","parameters":[{"name":"@r","value":"' + $runId + '"}]}'
    $req.Content = New-Object System.Net.Http.StringContent($q, [Text.Encoding]::UTF8)
    $req.Content.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue("application/query+json")   # exactly this, no charset
    $r = $client.SendAsync($req).GetAwaiter().GetResult()
    if ([int]$r.StatusCode -ne 200) { throw "read-back query failed: HTTP $([int]$r.StatusCode) $($r.Content.ReadAsStringAsync().GetAwaiter().GetResult())" }
    $json = $r.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
    foreach ($d in @($json.Documents)) { [void]$stored.Add([int]$d.seq) }
    $cont = $null; $vals = $null
    if ($r.Headers.TryGetValues("x-ms-continuation", [ref]$vals)) { $cont = @($vals)[0] }
} while ($cont)

$acked  = @($all | Where-Object { $_.Code -eq 201 } | ForEach-Object Seq)
$lost   = @($acked | Where-Object { -not $stored.Contains($_) })
$ackedSet = New-Object System.Collections.Generic.HashSet[int]; $acked | ForEach-Object { [void]$ackedSet.Add($_) }
$attempted = New-Object System.Collections.Generic.HashSet[int]; $all | ForEach-Object { [void]$attempted.Add($_.Seq) }
$notAcked = @($stored | Where-Object { -not $ackedSet.Contains($_) })
$unlogged = @($notAcked | Where-Object { -not $attempted.Contains($_) })   # stored, but no log row at all
$committedDespiteError = @($notAcked | Where-Object { $attempted.Contains($_) })   # client saw a failure, write was stored

function Window($f, $capMs) {
    if (-not $f) { return $null }
    $to = if ($f.Recovered -and $f.LastFailMs) { $f.LastFailMs + 20000 } else { $f.EndMs + 40000 }
    # Never reach into the next event: an overlapping window once made the failover report the failback's stall.
    if ($capMs) { $to = [Math]::Min($to, $capMs - 1) }
    $w = @($all | Where-Object { $_.T -ge ($f.StartMs - 1000) -and $_.T -le $to })
    $bad = @($w | Where-Object { $_.Code -ne 201 })
    $ok  = @($w | Where-Object { $_.Code -eq 201 })
    $first = $bad | Select-Object -First 1; $last = $bad | Select-Object -Last 1
    # longest time with no acknowledged write (counts a long stalled-then-successful write too)
    $ackT = @($ok | ForEach-Object { $_.T + $_.Ms }) | Sort-Object
    $gap = 0; for ($i = 1; $i -lt $ackT.Count; $i++) { $g = $ackT[$i] - $ackT[$i-1]; if ($g -gt $gap) { $gap = $g } }
    $slow = @($ok | Sort-Object Ms -Descending | Select-Object -First 1)
    # A write is logged at its START time and only when it returns, so a write stuck in SDK retries
    # (123 s under Strong in one run) is invisible to the acknowledged-gap figure. Report it separately.
    $stuck = @($w | Sort-Object Ms -Descending | Select-Object -First 1)
    [ordered]@{
        command_or_api_seconds                 = [math]::Round(($f.EndMs - $f.StartMs) / 1000, 1)
        recovered_within_limit                 = $f.Recovered
        failed_writes                          = $bad.Count
        write_outage_seconds_first_to_last_failure = $(if ($first) { [math]::Round((($last.T - $first.T) / 1000) + 0.2, 1) } else { 0 })
        longest_gap_between_acknowledged_writes_sec = [math]::Round($gap / 1000, 1)
        slowest_acknowledged_write_ms          = $(if ($slow) { $slow[0].Ms } else { $null })
        slowest_write_of_any_outcome_ms        = $(if ($stuck) { $stuck[0].Ms } else { $null })
        writes_slower_than_10s                 = @($w | Where-Object { $_.Ms -gt 10000 }).Count
        failure_status_codes                   = (($bad | Group-Object Code | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ", ")
        failure_substatus                      = (($bad | Group-Object Sub  | ForEach-Object { "'$($_.Name)' x$($_.Count)" }) -join ", ")
        failure_detail_sample                  = ($bad | Select-Object -First 1).Detail
    }
}
$res = [ordered]@{
    run                      = $stamp
    writer                   = $Writer
    scenario                 = $Scenario
    aborted                  = $aborted
    limits                   = "planned failover is not an unplanned outage; offlineRegion simulates an outage via API; one run; a naive REST client lags an SDK client"
    writes_attempted         = $all.Count
    writes_acknowledged      = $acked.Count
    documents_stored         = $stored.Count
    acknowledged_but_missing = $lost.Count
    missing_seqs_sample      = (($lost | Select-Object -First 10) -join ",")
    lost_write_window_seconds = $(if ($lost.Count) { $lt = @($all | Where-Object { $lost -contains $_.Seq } | ForEach-Object { $_.T }); [math]::Round((($lt | Measure-Object -Maximum).Maximum - ($lt | Measure-Object -Minimum).Minimum) / 1000 + 0.2, 1) } else { 0 })
    seconds_api_call_to_write_region_switch = $(if ($obs -and $f1) { $sw = @($obs | Where-Object { $_.WriteRegion -match 'France' } | Select-Object -First 1); if ($sw) { [math]::Round(($sw[0].T - $f1.StartMs) / 1000, 1) } else { "write region did not switch during the observation" } } else { $null })
    consistency_level        = (az cosmosdb show -n $Account -g $ResourceGroup --query consistencyPolicy.defaultConsistencyLevel -o tsv)
    stored_with_no_log_row   = $unlogged.Count
    stored_despite_client_error = $committedDespiteError.Count
    first_event              = Window $f1 $(if ($f2) { $f2.StartMs } else { $null })
    second_event             = Window $f2 $null
}
$res | ConvertTo-Json -Depth 4 | Set-Content "$root\docs\metrics\drill-cosmos-$tag-$stamp.json"
"`n=== RESULT [$tag] ==="; $res | ConvertTo-Json -Depth 4
"raw rows: $csv"
