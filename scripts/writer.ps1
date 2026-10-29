# Continuous Cosmos DB writer for the failover drill (Entra ID auth, REST). One CSV row per write:
#   epoch_ms_start, seq, http_status (0 = no response), latency_ms
# A write counts as ACKNOWLEDGED only on HTTP 201. Failed writes are NOT retried, so the log shows
# exactly what a client would have seen, and acknowledged-but-missing documents mean data loss.
param(
    [Parameter(Mandatory)][string]$Account,
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][string]$OutCsv,
    [Parameter(Mandatory)][string]$StopFile,
    [int]$TimeoutSec = 5
)
Add-Type -AssemblyName System.Net.Http
$endpoint = "https://$Account.documents.azure.com"
$token = az account get-access-token --resource $endpoint --query accessToken -o tsv
$auth  = [uri]::EscapeDataString("type=aad&ver=1.0&sig=$token")
$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
"epoch_ms,seq,http_status,substatus,latency_ms,detail" | Set-Content $OutCsv
$seq = 0
while (-not (Test-Path $StopFile)) {
    $seq++
    $t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $sub = ""; $detail = ""
    try {
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, "$endpoint/dbs/drdb/colls/ledger/docs")
        $req.Headers.TryAddWithoutValidation("Authorization", $auth) | Out-Null
        $req.Headers.TryAddWithoutValidation("x-ms-date", [DateTime]::UtcNow.ToString("r").ToLowerInvariant()) | Out-Null
        $req.Headers.TryAddWithoutValidation("x-ms-version", "2018-12-31") | Out-Null
        $req.Headers.TryAddWithoutValidation("x-ms-documentdb-partitionkey", '["drill"]') | Out-Null
        $body = '{"id":"' + $RunId + '-' + $seq + '","accountId":"drill","runId":"' + $RunId + '","seq":' + $seq + ',"ts":' + $t0 + '}'
        $req.Content = New-Object System.Net.Http.StringContent($body, [Text.Encoding]::UTF8, "application/json")
        $r = $client.SendAsync($req).GetAwaiter().GetResult()
        $code = [int]$r.StatusCode
        if ($code -ne 201) {
            $v = $null
            if ($r.Headers.TryGetValues("x-ms-substatus", [ref]$v)) { $sub = @($v)[0] }
            $detail = ($r.Content.ReadAsStringAsync().GetAwaiter().GetResult() -replace '[\r\n,"]', ' ')
            if ($detail.Length -gt 110) { $detail = $detail.Substring(0, 110) }
        }
        $r.Dispose()
    } catch { $code = 0; $detail = $_.Exception.GetType().Name }
    $sw.Stop()
    # The orchestrator reads this file while we append; a locked file once silently dropped two rows
    # (seq 449 and 479), so retry instead of losing the row.
    $line = "$t0,$seq,$code,$sub,$($sw.ElapsedMilliseconds),$detail"
    for ($try = 0; $try -lt 10; $try++) {
        try { Add-Content -Path $OutCsv -Value $line -ErrorAction Stop; break } catch { Start-Sleep -Milliseconds 50 }
    }
    $left = 200 - $sw.ElapsedMilliseconds
    if ($left -gt 0) { Start-Sleep -Milliseconds $left }
}
