#Requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for alz-graph-queries ARG queries.
.DESCRIPTION
    Reads alz_additional_queries.json, runs each queryable item via Search-AzGraph,
    and returns an array of PSObjects with compliance results.
    Requires the Az.ResourceGraph module.
    Never throws: skips items that fail individually, warns on module absence.

    Source of truth for the query set is the canonical upstream repo
    https://github.com/martinopedal/alz-graph-queries. That repo owns the query
    schema (every query MUST emit a boolean `compliant` column) and the
    validation tooling. The local queries/alz/alz_additional_queries.json file in
    this repo is a cached snapshot of that upstream JSON; refresh it with
    scripts/Sync-AlzQueries.ps1 (issue #315, in flight) or by copying
    alz_additional_queries.json from a fresh clone of alz-graph-queries.
    See the README.md "ALZ queries" section for the full provenance chain.
.PARAMETER SubscriptionId
    Scope queries to a specific subscription.
.PARAMETER ManagementGroupId
    Scope queries to a management group.
.PARAMETER QueriesFile
    Path to alz_additional_queries.json (cached snapshot of the canonical
    martinopedal/alz-graph-queries upstream).
    Defaults to .\queries\alz\alz_additional_queries.json relative to this script.
#>
[CmdletBinding(DefaultParameterSetName = 'Subscription')]
param (
    [Parameter(Mandatory, ParameterSetName = 'Subscription')]
    [ValidateNotNullOrEmpty()]
    [string] $SubscriptionId,

    [Parameter(Mandatory, ParameterSetName = 'ManagementGroup')]
    [ValidateNotNullOrEmpty()]
    [string] $ManagementGroupId,

    [string] $QueriesFile = (Join-Path $PSScriptRoot '..' 'queries' 'alz' 'alz_additional_queries.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sanitizePath = Join-Path $PSScriptRoot 'shared' 'Sanitize.ps1'
if (Test-Path $sanitizePath) { . $sanitizePath }
$missingToolPath = Join-Path $PSScriptRoot 'shared' 'MissingTool.ps1'
if (Test-Path $missingToolPath) { . $missingToolPath }
$envelopePath = Join-Path $PSScriptRoot 'shared' 'New-WrapperEnvelope.ps1'
if (Test-Path $envelopePath) { . $envelopePath }
if (-not (Get-Command New-WrapperEnvelope -ErrorAction SilentlyContinue)) { function New-WrapperEnvelope { param([string]$Source,[string]$Status='Failed',[string]$Message='',[object[]]$FindingErrors=@()) return [PSCustomObject]@{ Source=$Source; SchemaVersion='1.0'; Status=$Status; Message=$Message; Findings=@(); Errors=@($FindingErrors) } } }
if (-not (Get-Command New-FindingError -ErrorAction SilentlyContinue)) {
    function New-FindingError { param([string]$Source,[string]$Category,[string]$Reason,[string]$Remediation,[string]$Details) return [pscustomobject]@{ Source=$Source; Category=$Category; Reason=$Reason; Remediation=$Remediation; Details=$Details } }
}
if (-not (Get-Command Format-FindingErrorMessage -ErrorAction SilentlyContinue)) {
    function Format-FindingErrorMessage { param([Parameter(Mandatory)]$FindingError) $line = "[{0}] {1}: {2}" -f $FindingError.Source, $FindingError.Category, $FindingError.Reason; if ($FindingError.Remediation) { $line += " Action: $($FindingError.Remediation)" }; return $line }
}
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param([string]$Text) return $Text }
}
if (-not (Get-Command Write-MissingToolNotice -ErrorAction SilentlyContinue)) {
    function Write-MissingToolNotice { param([string]$Tool, [string]$Message) Write-Warning $Message }
}

# Dot-source retry helper so Search-AzGraph calls transparently handle
# Azure Resource Graph throttling (429) and transient service errors.
. (Join-Path $PSScriptRoot 'shared' 'Retry.ps1')

if (-not (Get-Module -Name Az.ResourceGraph -ListAvailable -ErrorAction SilentlyContinue)) {
    Write-MissingToolNotice -Tool 'alz-queries' -Message "Az.ResourceGraph module not installed. Skipping ALZ queries. Run: Install-Module Az.ResourceGraph"
    return [PSCustomObject]@{
        Source   = 'alz-queries'
        SchemaVersion = '1.0'
        Status   = 'Skipped'
        Message  = 'Az.ResourceGraph not installed'
        Findings = @()
        Errors   = @()
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
        Errors   = @()
    }
}

try {
    $data = Get-Content $QueriesFile -Raw | ConvertFrom-Json -ErrorAction Stop
} catch {
    $parseErr = New-FindingError -Source 'wrapper:alz-queries' -Category 'ParseError' -Reason "Failed to parse query file '$(Remove-Credentials -Text $QueriesFile)': $(Remove-Credentials -Text $_)" -Remediation 'Ensure the queries JSON file is valid JSON.'
    return (New-WrapperEnvelope -Source 'alz-queries' -Status 'Failed' -Message (Format-FindingErrorMessage $parseErr) -FindingErrors @($parseErr))
}
$queryable = $data.queries | Where-Object { $_.queryable -eq $true -and $_.graph }
$toolVersion = if ($data.PSObject.Properties['metadata'] -and $data.metadata -and $data.metadata.PSObject.Properties['version']) {
    [string]$data.metadata.version
} else {
    ''
}
$upstreamQueryFile = 'https://github.com/martinopedal/alz-graph-queries/blob/main/alz_additional_queries.json'

if ($queryable.Count -eq 0) {
    Write-Warning "No queryable items found in $QueriesFile"
    return [PSCustomObject]@{
        Source   = 'alz-queries'
        SchemaVersion = '1.0'
        Status   = 'Skipped'
        Message  = 'No queryable items found'
        Findings = @()
        Errors   = @()
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
            Id           = $item.guid
            Title        = $item.text
            Category     = $item.category
            Subcategory  = $item.subcategory
            Severity     = $item.severity
            Compliant    = $compliant
            Detail       = if ($compliant) {
                               if ($rows.Count -eq 0) { 'No resources in scope' } else { "All $($rows.Count) resource(s) compliant" }
                           } else {
                               "$($nonCompliantRows.Count) of $($rows.Count) resource(s) non-compliant"
                           }
            ResourceId   = $firstId
            LearnMoreUrl = ''
            QueryIntent  = if ($item.PSObject.Properties['queryIntent']) { [string]$item.queryIntent } else { '' }
            Description  = if ($item.PSObject.Properties['description']) { [string]$item.description } else { '' }
            QuerySource  = $upstreamQueryFile
            ToolVersion  = $toolVersion
        })
    } catch {
        Write-Warning "ALZ query failed for $($item.guid): $(Remove-Credentials -Text ([string]$_))"
        $findings.Add([PSCustomObject]@{
            Id           = $item.guid
            Title        = $item.text
            Category     = $item.category
            Subcategory  = $item.subcategory
            Severity     = $item.severity
            Compliant    = $false
            Detail       = (Remove-Credentials -Text "Query error: $([string]$_)")
            ResourceId   = ''
            LearnMoreUrl = ''
            QueryIntent  = if ($item.PSObject.Properties['queryIntent']) { [string]$item.queryIntent } else { '' }
            Description  = if ($item.PSObject.Properties['description']) { [string]$item.description } else { '' }
            QuerySource  = $upstreamQueryFile
            ToolVersion  = $toolVersion
        })
    }
}

return [PSCustomObject]@{
    Source   = 'alz-queries'
    SchemaVersion = '1.0'
    ToolVersion = $toolVersion
    Status   = 'Success'
    Message  = ''
    Findings = @($findings.ToArray())
    Errors   = @()
}
