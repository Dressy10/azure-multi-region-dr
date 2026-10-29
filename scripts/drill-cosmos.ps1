# Cosmos DB failover drill: fail the account over to the DR region and back while a writer logs every
# acknowledged write, then compare the log with what is actually stored.
# LIMITS: `failover-priority-change` is a PLANNED (graceful) failover, so it does not measure the data
# loss of an unplanned regional outage. The writer is a bare REST client with NO SDK write-region
# discovery, so its outage windows are what a naive client sees, not what the official SDKs would see.
param(
    [string]$Account = "cosmos-drproj-76256c",
    [string]$ResourceGroup = "rg-drproj-global",
    [string]$Primary = "uksouth",
    [string]$Dr = "francecentral"
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Net.Http
$root  = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$runId = "drill$stamp"
$csv   = "$root\docs\metrics\drill-cosmos-$stamp.csv"
$evf   = "$root\docs\metrics\drill-cosmos-$stamp.events.json"
$stop  = "$env:TEMP\cosmos-stop-$stamp"
New-Item -ItemType Directory -Force "$root\docs\metrics" | Out-Null
function Now-Ms { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
function Rows { Import-Csv $csv | ForEach-Object { [pscustomobject]@{ T = [long]$_.epoch_ms; Seq = [int]$_.seq; Code = [int]$_.http_status; Sub = $_.substatus; Ms = [int]$_.latency_ms; Detail = $_.detail } } }
function Clock([long]$ms) { [DateTimeOffset]::FromUnixTimeMilliseconds($ms).ToString("HH:mm:ss.fff") }
$events = New-Object System.Collections.ArrayList

# Data-plane access: account keys are disabled, so the signed-in user needs a Cosmos data role.
$oid = az ad signed-in-user show --query id -o tsv
$existing = @(az cosmosdb sql role assignment list -a $Account -g $ResourceGroup -o json | ConvertFrom-Json | Where-Object { $_.principalId -eq $oid })
if (-not $existing.Count) {
    "granting the signed-in user Cosmos DB Built-in Data Contributor on this account (removed when the stack is destroyed)"
    az cosmosdb sql role assignment create -a $Account -g $ResourceGroup --role-definition-id 00000000-0000-0000-0000-000000000002 --principal-id $oid --scope "/" | Out-Null
    Start-Sleep 60
}

$writer = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile","-File","$PSScriptRoot\writer.ps1","-Account",$Account,"-RunId",$runId,"-OutCsv",$csv,"-StopFile",$stop
Start-Sleep 25
$base = @(Rows)
$okBase = @($base | Where-Object { $_.Code -eq 201 }).Count
"baseline: $($base.Count) writes, $okBase acknowledged (201)"
if ($okBase -lt 20) { New-Item $stop | Out-Null; throw "Writer is not getting 201s (status codes: $((($base | Group-Object Code | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', ')))." }

# Recovered = no non-201 in the last 15 s, with the writer still alive and writing.
function Wait-Recovered([long]$since, [int]$maxSec = 420) {
    $deadline = (Get-Date).AddSeconds($maxSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep 5
        $r = @(Rows | Where-Object { $_.T -ge $since })
        $now = Now-Ms
        $recent = @($r | Where-Object { $_.T -ge ($now - 15000) })
        if ($recent.Count -ge 20 -and @($recent | Where-Object { $_.Code -ne 201 }).Count -eq 0) {
            $lastBad = $r | Where-Object { $_.Code -ne 201 } | Select-Object -Last 1
            return [pscustomobject]@{ Recovered = $true; LastFailMs = $(if ($lastBad) { $lastBad.T } else { $null }) }
        }
    }
    return [pscustomobject]@{ Recovered = $false; LastFailMs = $null }
}

function Failover($label, $first, $second) {
    "--- $label : $first=0 $second=1"
    $s = Now-Ms
    az cosmosdb failover-priority-change -n $Account -g $ResourceGroup --failover-policies "$first=0" "$second=1" | Out-Null
    $e = Now-Ms
    "    command took $([math]::Round(($e-$s)/1000))s; waiting for writes to recover"
    $rec = Wait-Recovered $s
    $ev = [pscustomobject]@{ Label = $label; StartMs = $s; EndMs = $e; Recovered = $rec.Recovered; LastFailMs = $rec.LastFailMs }
    [void]$events.Add($ev)
    $events | ConvertTo-Json | Set-Content $evf          # saved immediately: a later crash cannot lose these
    "    recovered: $($rec.Recovered)"
    $ev
}
$f1 = Failover "failover to DR" $Dr $Primary
$f2 = Failover "failback to primary" $Primary $Dr
Start-Sleep 5
New-Item $stop | Out-Null; Start-Sleep 3
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
    # The query API needs exactly application/query+json: .NET's default adds "; charset=utf-8", which makes
    # Cosmos treat the POST as a document create (HTTP 400 "id missing").
    $req.Content.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue("application/query+json")
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
$phantom = @($stored | Where-Object { -not $ackedSet.Contains($_) })

function Window($f) {
    $to = if ($f.Recovered) { $f.LastFailMs + 20000 } else { $f.EndMs + 60000 }
    $w = @($all | Where-Object { $_.T -ge ($f.StartMs - 1000) -and $_.T -le $to })
    $bad = @($w | Where-Object { $_.Code -ne 201 })
    $first = $bad | Select-Object -First 1; $last = $bad | Select-Object -Last 1
    [ordered]@{
        command_seconds                  = [math]::Round(($f.EndMs - $f.StartMs) / 1000, 1)
        recovered_within_limit           = $f.Recovered
        failed_writes                    = $bad.Count
        seconds_command_start_to_first_failure = $(if ($first) { [math]::Round(($first.T - $f.StartMs) / 1000, 1) } else { $null })
        seconds_command_start_to_last_failure  = $(if ($last)  { [math]::Round(($last.T  - $f.StartMs) / 1000, 1) } else { $null })
        write_outage_seconds_first_to_last_failure = $(if ($first) { [math]::Round((($last.T - $first.T) / 1000) + 0.2, 1) } else { 0 })
        failure_status_codes             = (($bad | Group-Object Code | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ", ")
        failure_substatus                = (($bad | Group-Object Sub  | ForEach-Object { "'$($_.Name)' x$($_.Count)" }) -join ", ")
        failure_detail_sample            = ($bad | Select-Object -First 1).Detail
    }
}
$res = [ordered]@{
    run                      = $stamp
    method                   = "REST writer ~5 writes/s with Entra auth, no SDK region discovery; planned failover and failback; recovery = 15 s with no failed writes; read-back of every stored doc for the run"
    limits                   = "planned (graceful) failover is not an unplanned regional outage; a naive REST client is slower to follow a write-region change than the official SDKs"
    writes_attempted         = $all.Count
    writes_acknowledged      = $acked.Count
    documents_stored         = $stored.Count
    acknowledged_but_missing = $lost.Count
    stored_but_not_acked     = $phantom.Count
    missing_seqs_sample      = (($lost | Select-Object -First 10) -join ",")
    failover_to_dr           = Window $f1
    failback_to_primary      = Window $f2
}
$res | ConvertTo-Json -Depth 4 | Set-Content "$root\docs\metrics\drill-cosmos-$stamp.json"
"`n=== RESULT ==="; $res | ConvertTo-Json -Depth 4
"raw rows: $csv"
