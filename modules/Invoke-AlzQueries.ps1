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

if (-not (Get-Module -Name Az.ResourceGraph -ListAvailable -ErrorAction SilentlyContinue)) {
    Write-Warning "Az.ResourceGraph module not installed. Skipping ALZ queries. Run: Install-Module Az.ResourceGraph"
    return [PSCustomObject]@{
        Source   = 'alz-queries'
        Findings = @()
    }
}

Import-Module Az.ResourceGraph -ErrorAction SilentlyContinue

if (-not (Test-Path $QueriesFile)) {
    Write-Warning "ALZ queries file not found at: $QueriesFile"
    Write-Warning "Clone https://github.com/martinopedal/alz-graph-queries and run with -QueriesFile path."
    return [PSCustomObject]@{
        Source   = 'alz-queries'
        Findings = @()
    }
}

$data = Get-Content $QueriesFile -Raw | ConvertFrom-Json -ErrorAction Stop
$queryable = $data.queries | Where-Object { $_.queryable -eq $true -and $_.graph }

if ($queryable.Count -eq 0) {
    Write-Warning "No queryable items found in $QueriesFile"
    return [PSCustomObject]@{
        Source   = 'alz-queries'
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
        $rows = Search-AzGraph -Query $item.graph @graphParams -First 1000 -ErrorAction Stop
        $compliant = $rows.Count -gt 0

        $findings.Add([PSCustomObject]@{
            Id       = $item.guid
            Title    = $item.text
            Category = $item.category
            Severity = $item.severity
            Compliant = $compliant
            Detail   = if ($rows.Count -gt 0) { "Found $($rows.Count) resource(s)" } else { "No resources found" }
        })
    } catch {
        Write-Warning "ALZ query failed for $($item.guid): $_"
        $findings.Add([PSCustomObject]@{
            Id       = $item.guid
            Title    = $item.text
            Category = $item.category
            Severity = $item.severity
            Compliant = $false
            Detail   = "Query error: $_"
        })
    }
}

return [PSCustomObject]@{
    Source   = 'alz-queries'
    Findings = $findings.ToArray()
}
