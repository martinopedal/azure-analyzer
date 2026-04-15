#Requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for alz-graph-queries ARG queries and local azure-analyzer queries.
.DESCRIPTION
    Reads alz_additional_queries.json, runs each queryable item via Search-AzGraph,
    and returns an array of PSObjects with compliance results.
    Also auto-discovers and runs all *.json files in the queries/ directory
    (supporting the azure-analyzer query schema with a 'query' field).
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
$queryable = @($data.queries | Where-Object { $_.queryable -eq $true -and $_.graph })

# Also read local azure-analyzer queries from queries/ directory.
# These use the 'query' field (not 'graph') and wrap items in { "queries": [...] }.
# Empty results for a query mean no resources in scope -- not non-compliant.
$localQueriesDir = Join-Path $PSScriptRoot '..' 'queries'
if (Test-Path $localQueriesDir) {
    $localQueryFiles = Get-ChildItem -Path $localQueriesDir -Filter '*.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'alz_additional_queries.json' }
    foreach ($qf in $localQueryFiles) {
        try {
            $localData = Get-Content $qf.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
            $localItems = if ($localData.PSObject.Properties['queries']) { $localData.queries } else { $localData }
            $queryable += @($localItems | Where-Object { $_.PSObject.Properties['query'] -and $_.query -and -not $_.not_queryable_reason })
        } catch {
            Write-Warning "Failed to parse $($qf.Name): $_"
        }
    }
}

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
        # Support both 'graph' (alz-graph-queries format) and 'query' (azure-analyzer format)
        $kql = if ($item.PSObject.Properties['graph'] -and $item.graph) { $item.graph }
               elseif ($item.PSObject.Properties['query'] -and $item.query) { $item.query }
               else { $null }
        if (-not $kql) { continue }

        $rows = Search-AzGraph -Query $kql @graphParams -First 1000 -ErrorAction Stop
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

        $findings.Add([PSCustomObject]@{
            Id       = $item.guid
            Title    = $item.text
            Category = $item.category
            Severity = $item.severity
            Compliant = $compliant
            Detail   = if ($compliant) {
                           if ($rows.Count -eq 0) { 'No resources in scope' } else { "All $($rows.Count) resource(s) compliant" }
                       } else {
                           "$($nonCompliantRows.Count) of $($rows.Count) resource(s) non-compliant"
                       }
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
