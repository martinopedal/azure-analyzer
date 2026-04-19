#Requires -Version 7.4
<#
.SYNOPSIS
    HTTP-triggered Azure Function entry for on-demand azure-analyzer runs.
.DESCRIPTION
    POST body (JSON, all fields optional; env defaults from Function App settings):
      {
        "subscriptionId": "<guid>",
        "tenantId":       "<guid>",
        "includeTools":   ["azqr","psrule"]
      }

    `includeTools` values are validated against an allow-list in
    Invoke-FunctionScan to prevent request-driven scope creep.
    authLevel is "function" (per-function key); intended as a break-glass
    on-demand path. Primary trigger is TimerScan.
#>
param ($Request, $TriggerMetadata)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..' 'Shared' 'Invoke-FunctionScan.ps1')

$body = @{}
try {
    if ($Request -and $Request.Body) {
        if ($Request.Body -is [string] -and -not [string]::IsNullOrWhiteSpace($Request.Body)) {
            $parsed = $Request.Body | ConvertFrom-Json -Depth 6 -AsHashtable -ErrorAction Stop
            if ($parsed -is [hashtable]) { $body = $parsed }
        } elseif ($Request.Body -is [hashtable]) {
            $body = $Request.Body
        } elseif ($Request.Body -is [pscustomobject]) {
            $body = @{}
            foreach ($p in $Request.Body.PSObject.Properties) { $body[$p.Name] = $p.Value }
        }
    }
} catch {
    $msg = Remove-Credentials "$_"
    Push-OutputBinding -Name Response -Value @{
        StatusCode = 400
        Body       = @{ error = "Invalid JSON body: $msg" } | ConvertTo-Json -Compress
        Headers    = @{ 'Content-Type' = 'application/json' }
    }
    return
}

try {
    $result = Invoke-FunctionScan -RequestBody $body -TriggerName 'http'
    Push-OutputBinding -Name Response -Value @{
        StatusCode = 200
        Body       = @{
            runId      = $result.RunId
            trigger    = $result.Trigger
            outputPath = $result.OutputPath
            sink       = $result.Sink
        } | ConvertTo-Json -Depth 6 -Compress
        Headers    = @{ 'Content-Type' = 'application/json' }
    }
} catch {
    $msg = Remove-Credentials "$_"
    Write-Error "[HttpScan] $msg"
    Push-OutputBinding -Name Response -Value @{
        StatusCode = 500
        Body       = @{ error = $msg } | ConvertTo-Json -Compress
        Headers    = @{ 'Content-Type' = 'application/json' }
    }
}
