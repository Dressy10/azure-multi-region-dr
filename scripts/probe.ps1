# Client-side probe: one request every ~500 ms until a stop file appears. One CSV row per request,
# so RTO and failed-request counts come from what a client actually saw, not from Azure's status fields.
#   columns: epoch_ms, http_status (0 = no response), body, latency_ms
param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$OutCsv,
    [Parameter(Mandatory)][string]$StopFile,
    [int]$TimeoutSec = 3
)
Add-Type -AssemblyName System.Net.Http
$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
"epoch_ms,http_status,body,latency_ms" | Set-Content $OutCsv
while (-not (Test-Path $StopFile)) {
    $t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = $client.GetAsync($Url).GetAwaiter().GetResult()
        $body = ($r.Content.ReadAsStringAsync().GetAwaiter().GetResult() -replace '[\r\n,]', ' ')
        if ($body.Length -gt 40) { $body = $body.Substring(0, 40) }   # error pages are huge; keep a short tag
        $code = [int]$r.StatusCode
    } catch { $code = 0; $body = "" }
    $sw.Stop()
    "$t0,$code,$body,$($sw.ElapsedMilliseconds)" | Add-Content $OutCsv
    $left = 500 - $sw.ElapsedMilliseconds
    if ($left -gt 0) { Start-Sleep -Milliseconds $left }
}
