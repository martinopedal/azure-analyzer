#Requires -Version 7.4
<#
.SYNOPSIS
    Multi-tenant fan-out orchestration for azure-analyzer (#163).
.DESCRIPTION
    Iterates over a list of tenants, invokes Invoke-AzureAnalyzer.ps1 per
    (tenant, subscription) pair as a child pwsh process to guarantee a clean
    Az / Microsoft.Graph context, captures sanitized stderr, recovers from
    per-tenant failures, and writes an aggregate summary
    (multi-tenant-summary.json + .html).

    v1 contract: sequential execution. Parallelism is deferred to a follow-up
    issue once cross-tenant identity correlation (#181) lands.
#>
[CmdletBinding()]
param ()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sanitizePath = Join-Path $PSScriptRoot 'Sanitize.ps1'
if (Test-Path $sanitizePath) { . $sanitizePath }
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param ([string] $Text) return $Text }
}

$script:MultiTenantSummarySchemaVersion = '1.0'
$script:MultiTenantStderrCapBytes       = 8192
$script:MultiTenantGuidPattern          = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
# Strip CommonParameters so child processes do not inherit -Verbose / -Debug
# noise and to avoid leaking *Variable bindings across processes.
$script:MultiTenantStripParams = @(
    'Verbose','Debug','ErrorAction','WarningAction','InformationAction',
    'ErrorVariable','WarningVariable','InformationVariable','OutVariable',
    'OutBuffer','PipelineVariable','ProgressAction',
    # Parameters that the child must NOT inherit because they are owned by
    # the multi-tenant layer or are being overridden per-tenant.
    'TenantConfig','Tenants','TenantId','SubscriptionId','OutputPath','ManagementGroupId'
)

function ConvertFrom-TenantConfig {
    <#
    .SYNOPSIS
        Normalize either a JSON config file or a raw string[] of tenant GUIDs
        into a uniform array of tenant descriptor objects.
    .DESCRIPTION
        Accepts -Path (a JSON file: [{"tenantId":"<guid>","subscriptionIds":["..."],"label":"prod"}])
        or -TenantList (string[] of GUIDs). Validates GUID shape on tenantId.
        Returns [pscustomobject]@{ TenantId; SubscriptionIds; Label } per entry.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param (
        [Parameter(ParameterSetName = 'Path')]
        [string] $Path,
        [Parameter(ParameterSetName = 'List')]
        [string[]] $TenantList
    )

    $entries = @()
    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            throw "ConvertFrom-TenantConfig: -Path is required."
        }
        if (-not (Test-Path -LiteralPath $Path)) {
            throw (Format-FindingErrorMessage (New-FindingError -Source 'shared:MultiTenantOrchestrator' `
                -Category 'NotFound' `
                -Reason "Tenant config file not found: $Path" `
                -Remediation 'Verify the -TenantConfig path exists and is readable.'))
        }
        $raw = Get-Content -LiteralPath $Path -Raw
        try {
            $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            throw (Remove-Credentials "Failed to parse tenant config '$Path': $($_.Exception.Message)")
        }
        # ConvertFrom-Json via pipeline unwraps single-element JSON arrays into
        # a bare pscustomobject. Re-wrap so we can iterate uniformly.
        if ($parsed -is [string] -or $parsed -is [System.ValueType]) {
            throw (Format-FindingErrorMessage (New-FindingError -Source 'shared:MultiTenantOrchestrator' `
                -Category 'ConfigurationError' `
                -Reason "Tenant config '$Path' must be a JSON array of tenant entries." `
                -Remediation 'Wrap the entries in [ ] (e.g. [{ "tenantId": "...", "subscriptionIds": [ ... ] }, ...]).'))
        }
        $entries = if ($parsed -is [System.Collections.IEnumerable]) { @($parsed) } else { @($parsed) }
    } else {
        if (-not $TenantList -or $TenantList.Count -eq 0) {
            throw "ConvertFrom-TenantConfig: -TenantList is empty."
        }
        $entries = @($TenantList | ForEach-Object {
            [pscustomobject]@{ tenantId = $_; subscriptionIds = @(); label = $null }
        })
    }

    $result = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    foreach ($entry in $entries) {
        if ($null -eq $entry) { continue }
        $tid = $null
        if ($entry.PSObject.Properties['tenantId']) { $tid = [string]$entry.tenantId }
        elseif ($entry.PSObject.Properties['TenantId']) { $tid = [string]$entry.TenantId }
        $tid = if ($tid) { $tid.Trim() } else { '' }
        if (-not ($tid -match $script:MultiTenantGuidPattern)) {
            throw (Remove-Credentials "Invalid tenantId '$tid' in tenant config (expected GUID).")
        }
        if ($seen.ContainsKey($tid.ToLowerInvariant())) {
            throw (Format-FindingErrorMessage (New-FindingError -Source 'shared:MultiTenantOrchestrator' `
                -Category 'ConfigurationError' `
                -Reason "Duplicate tenantId '$tid' in tenant config." `
                -Remediation 'Each tenantId must appear at most once; merge subscriptionIds into a single entry.'))
        }
        $seen[$tid.ToLowerInvariant()] = $true

        $subs = @()
        $subSrc = $null
        if ($entry.PSObject.Properties['subscriptionIds']) { $subSrc = $entry.subscriptionIds }
        elseif ($entry.PSObject.Properties['SubscriptionIds']) { $subSrc = $entry.SubscriptionIds }
        if ($subSrc) {
            $subs = @($subSrc | Where-Object { $_ } | ForEach-Object {
                $sid = ([string]$_).Trim()
                if (-not ($sid -match $script:MultiTenantGuidPattern)) {
                    throw (Remove-Credentials "Invalid subscriptionId '$sid' for tenant '$tid' (expected GUID).")
                }
                $sid
            })
        }

        $label = $null
        if ($entry.PSObject.Properties['label']) { $label = [string]$entry.label }
        elseif ($entry.PSObject.Properties['Label']) { $label = [string]$entry.Label }
        if ([string]::IsNullOrWhiteSpace($label)) { $label = $tid }

        $result.Add([pscustomobject]@{
            TenantId        = $tid
            SubscriptionIds = $subs
            Label           = $label
        })
    }
    return ,$result.ToArray()
}

function ConvertTo-ChildArgList {
    <#
    .SYNOPSIS
        Build a deterministic [string[]] argument list for `pwsh -File` from a
        hashtable of bound parameters, handling switches and arrays correctly.
    .DESCRIPTION
        - Strips MultiTenant-owned + CommonParameters (see $script:MultiTenantStripParams).
        - [switch] -> bare "-Name" when truthy; omitted when falsy.
        - Arrays / IEnumerable -> "-Name v1 v2 v3" (each token a separate element).
        - Null / empty string -> omitted.
        - Other scalars -> "-Name value".
        - Each value is appended as its own array element so PowerShell's native
          arg-passing handles quoting; never pre-concatenated.
    #>
    param (
        [Parameter(Mandatory)] [hashtable] $BoundParameters,
        [hashtable] $Override = @{}
    )

    $merged = @{}
    foreach ($k in $BoundParameters.Keys) {
        if ($k -in $script:MultiTenantStripParams) { continue }
        $merged[$k] = $BoundParameters[$k]
    }
    foreach ($k in $Override.Keys) { $merged[$k] = $Override[$k] }

    $out = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in ($merged.Keys | Sort-Object)) {
        $val = $merged[$name]
        if ($null -eq $val) { continue }

        if ($val -is [System.Management.Automation.SwitchParameter]) {
            if ($val.IsPresent) { $out.Add("-$name") }
            continue
        }
        if ($val -is [bool]) {
            if ($val) { $out.Add("-$name") }
            continue
        }
        if ($val -is [string]) {
            if ([string]::IsNullOrEmpty($val)) { continue }
            $out.Add("-$name"); $out.Add($val); continue
        }
        if ($val -is [System.Collections.IEnumerable] -and $val -isnot [string]) {
            $items = @($val | Where-Object { $null -ne $_ -and -not ([string]::IsNullOrEmpty([string]$_)) } | ForEach-Object { [string]$_ })
            if ($items.Count -eq 0) { continue }
            $out.Add("-$name")
            foreach ($i in $items) { $out.Add($i) }
            continue
        }
        $out.Add("-$name"); $out.Add([string]$val)
    }
    return ,$out.ToArray()
}

function Invoke-DefaultMultiTenantRunner {
    <#
    .SYNOPSIS
        Default child-process runner: spawns `pwsh -NoProfile -File` with a
        per-tenant stderr redirect file, caps captured stderr and sanitizes it.
    #>
    param (
        [Parameter(Mandatory)] [string]   $ScriptPath,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [string]   $WorkingDirectory,
        [int] $TimeoutSec = 3600
    )

    if (-not (Test-Path -LiteralPath $WorkingDirectory)) {
        $null = New-Item -ItemType Directory -Path $WorkingDirectory -Force
    }
    $stderrFile = Join-Path $WorkingDirectory '.child-stderr.log'
    $stdoutFile = Join-Path $WorkingDirectory '.child-stdout.log'

    $argv = @('-NoProfile','-NonInteractive','-File', $ScriptPath) + $Arguments
    $proc = Start-Process -FilePath 'pwsh' -ArgumentList $argv `
        -RedirectStandardError $stderrFile -RedirectStandardOutput $stdoutFile `
        -PassThru -NoNewWindow -WorkingDirectory $WorkingDirectory

    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try { $proc.Kill($true) } catch {
            Write-Verbose ("MultiTenantOrchestrator: child Process.Kill after timeout failed (process likely already exited). Reason: {0}" -f $_.Exception.Message)
        }
        return [pscustomobject]@{
            ExitCode = -1
            Stderr   = "Child process timed out after $TimeoutSec seconds."
        }
    }

    $stderr = ''
    if (Test-Path -LiteralPath $stderrFile) {
        try {
            $info = Get-Item -LiteralPath $stderrFile
            if ($info.Length -gt $script:MultiTenantStderrCapBytes) {
                $fs = [System.IO.File]::OpenRead($stderrFile)
                try {
                    $null = $fs.Seek(-$script:MultiTenantStderrCapBytes, 'End')
                    $reader = New-Object System.IO.StreamReader($fs)
                    $stderr = '...[truncated]...' + $reader.ReadToEnd()
                } finally { $fs.Dispose() }
            } else {
                $stderr = Get-Content -LiteralPath $stderrFile -Raw
            }
        } catch {
            $stderr = "Failed to read child stderr: $(Remove-Credentials $_.Exception.Message)"
        }
    }
    return [pscustomobject]@{
        ExitCode = $proc.ExitCode
        Stderr   = (Remove-Credentials $stderr)
    }
}

function Invoke-MultiTenantScan {
    <#
    .SYNOPSIS
        Fan out azure-analyzer across multiple tenants sequentially.
    .DESCRIPTION
        - Per-tenant output directory: $OutputPath/<tenantId>.
        - One child process per (tenant, subscription) pair. When a tenant has
          no subscriptionIds, a single tenant-only child is invoked.
        - Continues on per-tenant failure; records sanitized error.
        - Returns an aggregate summary object and writes:
            $OutputPath/multi-tenant-summary.json
            $OutputPath/multi-tenant-summary.html
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [object[]]  $Tenants,
        [Parameter(Mandatory)] [string]    $OutputPath,
        [Parameter(Mandatory)] [string]    $ScriptPath,
        [hashtable]                        $ForwardParams = @{},
        [scriptblock]                      $Runner,
        [int]                              $TimeoutSec = 3600
    )

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        $null = New-Item -ItemType Directory -Path $OutputPath -Force
    }
    $resolvedOutputPath = (Resolve-Path -LiteralPath $OutputPath).Path

    if (-not $Runner) {
        $Runner = {
            param ($childScript, $childArgs, $childWorkDir, $childTimeout)
            Invoke-DefaultMultiTenantRunner -ScriptPath $childScript -Arguments $childArgs `
                -WorkingDirectory $childWorkDir -TimeoutSec $childTimeout
        }
    }
    $tenantRecords = New-Object 'System.Collections.Generic.List[object]'
    foreach ($t in $Tenants) {
        $tenantDir = Join-Path $resolvedOutputPath $t.TenantId
        if (-not (Test-Path -LiteralPath $tenantDir)) {
            $null = New-Item -ItemType Directory -Path $tenantDir -Force
        }

        $subTargets = New-Object 'System.Collections.Generic.List[object]'
        if ($t.SubscriptionIds -and $t.SubscriptionIds.Count -gt 0) {
            foreach ($s in $t.SubscriptionIds) { $subTargets.Add($s) }
        } else {
            $subTargets.Add($null)  # tenant-only run sentinel
        }

        $tenantStatus      = 'success'
        $tenantExitCode    = 0
        $tenantErrors      = New-Object 'System.Collections.Generic.List[string]'
        $tenantStartedAt   = Get-Date
        $perRunArtifacts   = New-Object 'System.Collections.Generic.List[object]'

        foreach ($sub in $subTargets) {
            $childOutputDir = if ($sub) { Join-Path $tenantDir $sub } else { $tenantDir }
            if (-not (Test-Path -LiteralPath $childOutputDir)) {
                $null = New-Item -ItemType Directory -Path $childOutputDir -Force
            }
            $override = @{
                TenantId   = $t.TenantId
                OutputPath = $childOutputDir
            }
            if ($sub) { $override['SubscriptionId'] = $sub }
            $childArgs = ConvertTo-ChildArgList -BoundParameters $ForwardParams -Override $override

            $childResult = $null
            try {
                $childResult = & $Runner $ScriptPath $childArgs $childOutputDir $TimeoutSec
            } catch {
                $childResult = [pscustomobject]@{
                    ExitCode = -1
                    Stderr   = (Remove-Credentials "Runner threw: $($_.Exception.Message)")
                }
            }

            $exit = if ($childResult -and $childResult.PSObject.Properties['ExitCode']) { [int]$childResult.ExitCode } else { -1 }
            if ($exit -ne 0) {
                $tenantStatus   = 'failure'
                $tenantExitCode = $exit
                $msg = if ($childResult.PSObject.Properties['Stderr']) { [string]$childResult.Stderr } else { '' }
                if ([string]::IsNullOrWhiteSpace($msg)) { $msg = "Child exited with code $exit." }
                $tenantErrors.Add((Remove-Credentials $msg))
            }

            $perRunArtifacts.Add([pscustomobject]@{
                SubscriptionId = $sub
                OutputPath     = $childOutputDir
                ExitCode       = $exit
                Results        = (Join-Path $childOutputDir 'results.json')
                Entities       = (Join-Path $childOutputDir 'entities.json')
                Report         = (Join-Path $childOutputDir 'report.html')
            })
        }

        $tenantTotals = Get-MultiTenantSeverityTotals -Runs $perRunArtifacts
        $tenantRecord = [pscustomobject]@{
            TenantId         = $t.TenantId
            Label            = $t.Label
            Status           = $tenantStatus
            ExitCode         = $tenantExitCode
            DurationSeconds  = [math]::Round(((Get-Date) - $tenantStartedAt).TotalSeconds, 2)
            SubscriptionRuns = @($perRunArtifacts.ToArray())
            Totals           = $tenantTotals
            Error            = if ($tenantErrors.Count -gt 0) { ($tenantErrors -join "`n---`n") } else { $null }
        }
        $tenantRecords.Add($tenantRecord)
    }

    $records = @($tenantRecords.ToArray())
    $grandTotals = [ordered]@{
        Critical = 0; High = 0; Medium = 0; Low = 0; Info = 0
        Failed   = @($records | Where-Object { $_.Status -eq 'failure' }).Count
    }
    foreach ($r in $records) {
        foreach ($sev in 'Critical','High','Medium','Low','Info') {
            $grandTotals[$sev] += [int]$r.Totals.$sev
        }
    }

    $summary = [pscustomobject]@{
        SchemaVersion = $script:MultiTenantSummarySchemaVersion
        GeneratedAt   = (Get-Date).ToUniversalTime().ToString('o')
        ScriptPath    = (Remove-Credentials $ScriptPath)
        OutputPath    = $resolvedOutputPath
        Tenants       = $records
        Totals        = [pscustomobject]$grandTotals
    }

    $summaryJson = Join-Path $resolvedOutputPath 'multi-tenant-summary.json'
    $summaryHtml = Join-Path $resolvedOutputPath 'multi-tenant-summary.html'
    $jsonText = Remove-Credentials ($summary | ConvertTo-Json -Depth 8)
    Set-Content -LiteralPath $summaryJson -Value $jsonText -Encoding UTF8
    $htmlText = New-MultiTenantSummaryHtml -Summary $summary
    Set-Content -LiteralPath $summaryHtml -Value (Remove-Credentials $htmlText) -Encoding UTF8

    return $summary
}

function Get-MultiTenantSeverityTotals {
    param ([object[]] $Runs)
    $totals = [ordered]@{ Critical = 0; High = 0; Medium = 0; Low = 0; Info = 0 }
    foreach ($run in @($Runs)) {
        $resultsPath = $run.Results
        if (-not (Test-Path -LiteralPath $resultsPath)) { continue }
        try {
            $payload = Get-Content -LiteralPath $resultsPath -Raw | ConvertFrom-Json -ErrorAction Stop
        } catch { continue }
        $findings = @(
            if ($payload.PSObject.Properties['Findings']) { $payload.Findings }
            elseif ($payload.PSObject.Properties['findings']) { $payload.findings }
            else { $payload }
        )
        foreach ($f in $findings) {
            $sev = $null
            if ($f.PSObject.Properties['Severity']) { $sev = [string]$f.Severity }
            elseif ($f.PSObject.Properties['severity']) { $sev = [string]$f.severity }
            if (-not $sev) { continue }
            $key = ($sev.Substring(0,1).ToUpperInvariant() + $sev.Substring(1).ToLowerInvariant())
            if ($totals.Contains($key)) { $totals[$key]++ }
        }
    }
    return [pscustomobject]$totals
}

function ConvertTo-MultiTenantHtmlText {
    param ([string] $Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    return $Value.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;').Replace("'",'&#39;')
}

function New-MultiTenantSummaryHtml {
    param ([Parameter(Mandatory)] [object] $Summary)
    $rows = New-Object System.Text.StringBuilder
    foreach ($t in @($Summary.Tenants)) {
        $statusClass = if ($t.Status -eq 'success') { 'ok' } else { 'fail' }
        $reportLink = if ($t.SubscriptionRuns -and $t.SubscriptionRuns.Count -gt 0) {
            $first = $t.SubscriptionRuns[0]
            "<a href=`"$(ConvertTo-MultiTenantHtmlText ([string]$first.Report))`">report</a>"
        } else { '' }
        [void]$rows.AppendLine("<tr class=`"$statusClass`"><td>$(ConvertTo-MultiTenantHtmlText ([string]$t.Label))</td><td><code>$(ConvertTo-MultiTenantHtmlText ([string]$t.TenantId))</code></td><td>$(ConvertTo-MultiTenantHtmlText ([string]$t.Status))</td><td>$($t.Totals.Critical)</td><td>$($t.Totals.High)</td><td>$($t.Totals.Medium)</td><td>$($t.Totals.Low)</td><td>$($t.Totals.Info)</td><td>$($t.DurationSeconds)s</td><td>$reportLink</td></tr>")
    }
    $tot = $Summary.Totals
    return @"
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Multi-Tenant Summary</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222}
h1{margin-bottom:4px}
.meta{color:#666;font-size:0.9em;margin-bottom:16px}
table{border-collapse:collapse;width:100%}
th,td{border:1px solid #ddd;padding:6px 10px;text-align:left;font-size:0.92em}
th{background:#f4f4f4}
tr.fail{background:#fff1f1}
tr.ok{background:#f6fff6}
.totals{margin-top:18px;font-weight:600}
.crit{color:#a00}.high{color:#c60}.med{color:#a80}.low{color:#080}.info{color:#06c}
</style></head><body>
<h1>Multi-Tenant Summary</h1>
<div class="meta">Generated $($Summary.GeneratedAt) &middot; SchemaVersion $($Summary.SchemaVersion) &middot; $($Summary.Tenants.Count) tenant(s)</div>
<table>
<thead><tr><th>Label</th><th>Tenant</th><th>Status</th><th>Crit</th><th>High</th><th>Med</th><th>Low</th><th>Info</th><th>Duration</th><th>Report</th></tr></thead>
<tbody>
$($rows.ToString())
</tbody></table>
<div class="totals">Totals: <span class="crit">Critical $($tot.Critical)</span> &middot; <span class="high">High $($tot.High)</span> &middot; <span class="med">Medium $($tot.Medium)</span> &middot; <span class="low">Low $($tot.Low)</span> &middot; <span class="info">Info $($tot.Info)</span> &middot; Failed tenants: $($tot.Failed)</div>
</body></html>
"@
}

# Export discovery (no Export-ModuleMember in dot-source mode; functions are
# auto-available to the dot-sourcing scope).
