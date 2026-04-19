#Requires -Version 7.4
<#
.SYNOPSIS
    Timer-triggered Azure Function entry for azure-analyzer continuous control mode.
.DESCRIPTION
    Default cron is 06:00 UTC daily (NCRONTAB). Scan parameters are read from
    Function App settings (AZURE_ANALYZER_SUBSCRIPTION_ID etc.) -- there is no
    request body for timer triggers.

    Outputs are written under the OS temp dir. A follow-up issue covers
    persisting them to Blob Storage / Log Analytics; for now the optional
    Log Analytics sink (#162) is invoked when DCE_ENDPOINT is configured.
#>
param ($Timer)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..' 'Shared' 'Invoke-FunctionScan.ps1')

try {
    $result = Invoke-FunctionScan -TriggerName 'timer'
    Write-Host "[TimerScan] Run $($result.RunId) complete. Output: $($result.OutputPath)"
} catch {
    $sanitized = Remove-Credentials "$_"
    Write-Error "[TimerScan] $sanitized"
    throw
}
