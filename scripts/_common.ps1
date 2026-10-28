$ErrorActionPreference = "Stop"

$script:Root = Split-Path -Parent $PSScriptRoot
$script:SubscriptionId = (az account show --query id -o tsv)
$script:StateRg = "rg-drproj-tfstate"
$script:StateSa = (az storage account list -g $StateRg --query "[0].name" -o tsv)
$script:StackRgs = @("rg-drproj-global", "rg-drproj-primary", "rg-drproj-dr")

function Invoke-Tf {
    param([string[]]$TfArgs)
    $env:TF_VAR_subscription_id = $SubscriptionId
    terraform "-chdir=$Root\infra\stack" @TfArgs
    if ($LASTEXITCODE -ne 0) { throw "terraform $($TfArgs -join ' ') failed" }
}

function Initialize-Tf {
    Invoke-Tf @("init", "-input=false", "-reconfigure",
        "-backend-config=resource_group_name=$StateRg",
        "-backend-config=storage_account_name=$StateSa",
        "-backend-config=container_name=tfstate",
        "-backend-config=key=stack.tfstate",
        "-backend-config=use_azuread_auth=true")
}

function Write-Timing([string]$what, [double]$seconds) {
    $log = "$Root\docs\metrics\timings.log"
    New-Item -ItemType Directory -Force (Split-Path $log) | Out-Null
    "{0:o} {1} {2:n0}s" -f (Get-Date), $what, $seconds | Add-Content $log
}
