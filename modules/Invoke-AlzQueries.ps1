#Requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for alz-graph-queries ARG queries.
.DESCRIPTION
    Reads alz_additional_queries.json, runs each queryable item via Search-AzGraph,
    and returns an array of PSObjects with compliance results.
    Requires the Az.ResourceGraph module.
    Never throws — skips items that fail individually, warns on module absence.
.PARAMETER SubscriptionId
    Scope queries to a specific subscription.
.PARAMETER ManagementGroupId
    Scope queries to a management group.
.PARAMETER QueriesFile
    Path to alz_additional_queries.json.
    Defaults to .\queries\alz_additional_queries.json relative to this script.
#>
[CmdletBinding(DefaultParameterSetName = 'Subscription')]
param (
    [Parameter(Mandatory, ParameterSetName = 'Subscription')]
    [ValidateNotNullOrEmpty()]
    [string] $SubscriptionId,

    [Parameter(Mandatory, ParameterSetName = 'ManagementGroup')]
    [ValidateNotNullOrEmpty()]
    [string] $ManagementGroupId,

    [string] $QueriesFile = (Join-Path $PSScriptRoot '..' 'queries' 'alz_additional_queries.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sanitizePath = Join-Path $PSScriptRoot 'shared' 'Sanitize.ps1'
if (Test-Path $sanitizePath) { . $sanitizePath }
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param([string]$Text) return $Text }
}

# Dot-source retry helper so Search-AzGraph calls transparently handle
# Azure Resource Graph throttling (429) and transient service errors.
. (Join-Path $PSScriptRoot 'shared' 'Retry.ps1')

if (-not (Get-Module -Name Az.ResourceGraph -ListAvailable -ErrorAction SilentlyContinue)) {
    Write-Warning "Az.ResourceGraph module not installed. Skipping ALZ queries. Run: Install-Module Az.ResourceGraph"
    return [PSCustomObject]@{
        Source   = 'alz-queries'
        SchemaVersion = '1.0'
        Status   = 'Skipped'
        Message  = 'Az.ResourceGraph not installed'
        Findings = @()
    }
}

Import-Module Az.ResourceGraph -ErrorAction SilentlyContinue

if (-not (Test-Path $QueriesFile)) {
    Write-Warning "ALZ queries file not found at: $QueriesFile"
    Write-Warning "Clone https://github.com/martinopedal/alz-graph-queries and run with -QueriesFile path."
    return [PSCustomObject]@{
        Source   = 'alz-queries'
        SchemaVersion = '1.0'
        Status   = 'Skipped'
        Message  = 'Query file not found'
        Findings = @()
    }
}

$data = Get-Content $QueriesFile -Raw | ConvertFrom-Json -ErrorAction Stop
$queryable = $data.queries | Where-Object { $_.queryable -eq $true -and $_.graph }

if ($queryable.Count -eq 0) {
    Write-Warning "No queryable items found in $QueriesFile"
    return [PSCustomObject]@{
        Source   = 'alz-queries'
        SchemaVersion = '1.0'
        Status   = 'Skipped'
        Message  = 'No queryable items found'
        Findings = @()
    }
}

$graphParams = @{}
if ($PSCmdlet.ParameterSetName -eq 'ManagementGroup') {
    $graphParams['ManagementGroup'] = $ManagementGroupId
} else {
    $graphParams['Subscription'] = $SubscriptionId
}

$findings = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($item in $queryable) {
    try {
        $rows = Invoke-WithRetry -MaxAttempts 3 -BaseDelaySec 2 -MaxDelaySec 30 -ScriptBlock {
            Search-AzGraph -Query $item.graph @graphParams -First 1000 -ErrorAction Stop
        }
        # Queries return a 'compliant' boolean column.
        # No rows means no resources in scope — treat as compliant.
        if ($rows.Count -eq 0) {
            $compliant = $true
        } else {
            $nonCompliantRows = @($rows | Where-Object {
                $p = $_.PSObject.Properties['compliant']
                $p -and ($p.Value -eq $false -or $p.Value -eq 0)
            })
            $compliant = $nonCompliantRows.Count -eq 0
        }

        # Extract resource ID from first non-compliant row if available
        $firstId = ''
        if (-not $compliant -and $nonCompliantRows.Count -gt 0) {
            $idProp = $nonCompliantRows[0].PSObject.Properties['id']
            if ($idProp -and $idProp.Value) { $firstId = [string]$idProp.Value }
        }

        $findings.Add([PSCustomObject]@{
            Id          = $item.guid
            Title       = $item.text
            Category    = $item.category
            Severity    = $item.severity
            Compliant   = $compliant
            Detail      = if ($compliant) {
                              if ($rows.Count -eq 0) { 'No resources in scope' } else { "All $($rows.Count) resource(s) compliant" }
                          } else {
                              "$($nonCompliantRows.Count) of $($rows.Count) resource(s) non-compliant"
                          }
            ResourceId   = $firstId
            LearnMoreUrl = ''
        })
    } catch {
        Write-Warning "ALZ query failed for $($item.guid): $(Remove-Credentials -Text ([string]$_))"
        $findings.Add([PSCustomObject]@{
            Id           = $item.guid
            Title        = $item.text
            Category     = $item.category
            Severity     = $item.severity
            Compliant    = $false
            Detail       = (Remove-Credentials -Text "Query error: $([string]$_)")
            ResourceId   = ''
            LearnMoreUrl = ''
        })
    }
}

return [PSCustomObject]@{
    Source   = 'alz-queries'
    SchemaVersion = '1.0'
    Status   = 'Success'
    Message  = ''
    Findings = $findings.ToArray()
}
