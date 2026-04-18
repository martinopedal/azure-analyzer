#Requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for AzGovViz (Azure Governance Visualizer).
.DESCRIPTION
    Runs AzGovVizParallel.ps1 for a management group and returns a summary PSObject.
    If AzGovViz is not installed/found, writes a warning and returns empty result.
    Never throws.
.PARAMETER ManagementGroupId
    Management group ID to analyze.
.PARAMETER OutputPath
    Directory for AzGovViz output. Defaults to .\output\azgovviz.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ManagementGroupId,

    [string] $OutputPath = (Join-Path (Get-Location) 'output' 'azgovviz')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sanitizePath = Join-Path $PSScriptRoot 'shared' 'Sanitize.ps1'
if (Test-Path $sanitizePath) { . $sanitizePath }
$retryPath = Join-Path $PSScriptRoot 'shared' 'Retry.ps1'
if (Test-Path $retryPath) { . $retryPath }
$installerPath = Join-Path $PSScriptRoot 'shared' 'Installer.ps1'
if (Test-Path $installerPath) { . $installerPath }
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param([string]$Text) return $Text }
}
if (-not (Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue)) {
    function Invoke-WithRetry {
        param ([Parameter(Mandatory)][scriptblock]$ScriptBlock)
        return & $ScriptBlock
    }
}
if (-not (Get-Command Invoke-WithTimeout -ErrorAction SilentlyContinue)) {
    function Invoke-WithTimeout {
        param (
            [Parameter(Mandatory)][string]$Command,
            [Parameter(Mandatory)][string[]]$Arguments,
            [int]$TimeoutSec = 300
        )
        $output = & $Command @Arguments 2>&1 | Out-String
        return [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = $output.Trim() }
    }
}

function Find-AzGovViz {
    $candidates = [System.Collections.Generic.List[string]]::new()
    $candidates.Add((Join-Path (Get-Location) 'AzGovVizParallel.ps1'))
    $candidates.Add((Join-Path (Get-Location) 'tools' 'AzGovViz' 'AzGovVizParallel.ps1'))
    $candidates.Add((Join-Path (Split-Path $PSScriptRoot -Parent) 'tools' 'AzGovViz' 'AzGovVizParallel.ps1'))
    if ($env:USERPROFILE) {
        $candidates.Add((Join-Path $env:USERPROFILE 'AzGovViz' 'AzGovVizParallel.ps1'))
    }
    if ($env:HOME) {
        $candidates.Add((Join-Path $env:HOME 'AzGovViz' 'AzGovVizParallel.ps1'))
    }
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Get-RowValue {
    param (
        [Parameter(Mandatory)]
        [psobject] $Row,
        [Parameter(Mandatory)]
        [string[]] $Names
    )

    foreach ($name in $Names) {
        $prop = $Row.PSObject.Properties[$name]
        if ($null -eq $prop) { continue }
        $value = [string]$prop.Value
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }

    return ''
}

function ConvertTo-BooleanValue {
    param ([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    switch -Regex ($Value.Trim().ToLowerInvariant()) {
        '^(true|1|yes|y)$' { return $true }
        default { return $false }
    }
}

function Get-PolicyEffectSeverity {
    param ([string]$Effect)

    switch -Regex (($Effect ?? '').Trim().ToLowerInvariant()) {
        '^deny$' { return 'High' }
        '^audit$' { return 'Medium' }
        '^auditifnotexists$' { return 'Low' }
        default { return 'Medium' }
    }
}

function Import-AzGovVizCsvFindings {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $OutputPath
    )

    $findings = [System.Collections.Generic.List[psobject]]::new()
    $csvFiles = Get-ChildItem -Path $OutputPath -Filter '*.csv' -Recurse -ErrorAction SilentlyContinue

    foreach ($file in $csvFiles) {
        $fileName = $file.Name.ToLowerInvariant()
        try {
            $rows = Import-Csv -Path $file.FullName -ErrorAction Stop
        } catch {
            Write-Warning "Could not parse AzGovViz CSV $($file.Name): $(Remove-Credentials -Text ([string]$_))"
            continue
        }

        if (-not $rows) { continue }

        switch -Regex ($fileName) {
            'policycompliancestates' {
                foreach ($row in $rows) {
                    $effect = Get-RowValue -Row $row -Names @('PolicyEffect', 'effect')
                    $complianceState = Get-RowValue -Row $row -Names @('ComplianceState', 'complianceState')
                    $policyAssignment = Get-RowValue -Row $row -Names @('PolicyAssignmentName', 'policyAssignmentName', 'PolicyAssignment')
                    $resourceId = Get-RowValue -Row $row -Names @('ResourceId', 'resourceId', 'ResourceID', 'Scope', 'scope')
                    $scope = Get-RowValue -Row $row -Names @('Scope', 'scope')
                    $stateText = if ($complianceState) { $complianceState } else { 'Unknown' }
                    $isCompliant = ($complianceState -eq 'Compliant')
                    if ($isCompliant) { continue }
                    $titleSuffix = if ($policyAssignment) { ": $policyAssignment" } else { '' }
                    $findings.Add([pscustomobject]@{
                            Source      = 'azgovviz'
                            Category    = 'Policy'
                            Title       = "Policy compliance state$titleSuffix"
                            Compliant   = $false
                            Severity    = Get-PolicyEffectSeverity -Effect $effect
                            Detail      = "ComplianceState=$stateText; Effect=$effect; Scope=$scope"
                            ResourceId  = $resourceId
                            SchemaVersion = '1.0'
                        })
                }
            }
            'roleassignments' {
                foreach ($row in $rows) {
                    $principalId = Get-RowValue -Row $row -Names @('ObjectId', 'PrincipalId', 'principalId', 'AssigneeObjectId')
                    if (-not $principalId) { continue }

                    $roleName = Get-RowValue -Row $row -Names @('RoleDefinitionName', 'RoleName', 'roleDefinitionName')
                    $scope = Get-RowValue -Row $row -Names @('Scope', 'scope')
                    $principalType = Get-RowValue -Row $row -Names @('PrincipalType', 'principalType', 'ObjectType')
                    $isPrivilegedRole = $roleName -match '^(Owner|Contributor|User Access Administrator)$'
                    $isBroadScope = $scope -match '^/subscriptions/[^/]+$' -or $scope -match '^/providers/microsoft\.management/managementgroups/'
                    $isCompliant = -not ($isPrivilegedRole -and $isBroadScope)
                    if ($isCompliant) { continue }
                    $severity = 'High'

                    $findings.Add([pscustomobject]@{
                            Source        = 'azgovviz'
                            Category      = 'Identity'
                            Title         = "Role assignment: $roleName"
                            Compliant     = $false
                            Severity      = $severity
                            Detail        = "PrincipalType=$principalType; Scope=$scope"
                            ResourceId    = $scope
                            PrincipalId   = $principalId
                            PrincipalType = $principalType
                            SchemaVersion = '1.0'
                        })
                }
            }
            'resourcediagnosticscapabilit' {
                foreach ($row in $rows) {
                    $resourceId = Get-RowValue -Row $row -Names @('ResourceId', 'resourceId', 'ResourceID')
                    if (-not $resourceId) { continue }
                    $capable = ConvertTo-BooleanValue (Get-RowValue -Row $row -Names @('DiagnosticsCapable', 'diagnosticsCapable'))
                    $configured = ConvertTo-BooleanValue (Get-RowValue -Row $row -Names @('DiagnosticsConfigured', 'diagnosticsConfigured'))
                    if (-not $capable) { continue }
                    if ($configured) { continue }

                    $findings.Add([pscustomobject]@{
                            Source        = 'azgovviz'
                            Category      = 'Operations'
                            Title         = 'Resource diagnostics settings configured'
                            Compliant     = $false
                            Severity      = 'Medium'
                            Detail        = "DiagnosticsCapable=$capable; DiagnosticsConfigured=$configured"
                            ResourceId    = $resourceId
                            Remediation   = 'Enable diagnostic settings to route logs and metrics to an approved destination.'
                            SchemaVersion = '1.0'
                        })
                }
            }
            'resourceswithouttags' {
                foreach ($row in $rows) {
                    $resourceId = Get-RowValue -Row $row -Names @('ResourceId', 'resourceId', 'ResourceID')
                    if (-not $resourceId) { continue }
                    $missingTags = Get-RowValue -Row $row -Names @('MissingTags', 'missingTags', 'TagNames')

                    $findings.Add([pscustomobject]@{
                            Source        = 'azgovviz'
                            Category      = 'Governance'
                            Title         = 'Resource missing required tags'
                            Compliant     = $false
                            Severity      = 'Low'
                            Detail        = if ($missingTags) { "MissingTags=$missingTags" } else { 'Missing one or more required tags.' }
                            ResourceId    = $resourceId
                            Remediation   = 'Apply required governance tags according to your tagging policy.'
                            SchemaVersion = '1.0'
                        })
                }
            }
            default {
                Write-Verbose "Skipping unsupported AzGovViz CSV file: $($file.Name)"
            }
        }
    }

    return @($findings)
}

$azGovVizScript = Find-AzGovViz

if (-not $azGovVizScript) {
    Write-Warning "AzGovViz (AzGovVizParallel.ps1) not found. Skipping. Clone from https://github.com/JulianHayward/Azure-MG-Sub-Governance-Reporting"
    return [PSCustomObject]@{
        Source   = 'azgovviz'
        Status   = 'Skipped'
        Message  = 'AzGovVizParallel.ps1 not found'
        Findings = @()
    }
}

if (-not (Test-Path $OutputPath)) {
    $null = New-Item -ItemType Directory -Path $OutputPath -Force
}

try {
    Write-Verbose "Running AzGovViz for management group: $ManagementGroupId"
    $runAzGovViz = {
        $result = Invoke-WithTimeout -Command 'pwsh' -Arguments @(
            '-File', $azGovVizScript,
            '-ManagementGroupId', $ManagementGroupId,
            '-OutputPath', $OutputPath,
            '-AzureDevOpsWikiAsCode', 'False',
            '-HierarchyTreeOnly', 'False'
        ) -TimeoutSec 300
        if ($result.ExitCode -ne 0) {
            throw "AzGovViz exited with code $($result.ExitCode): $($result.Output)"
        }
    }
    Invoke-WithRetry -ScriptBlock $runAzGovViz -MaxAttempts 3 -InitialDelaySeconds 2 -MaxDelaySeconds 10 | Out-Null

    $summaryFiles = Get-ChildItem -Path $OutputPath -Filter '*Summary*.json' -Recurse -ErrorAction SilentlyContinue
    $findings = [System.Collections.Generic.List[psobject]]::new()
    foreach ($file in $summaryFiles) {
        try {
            $data = Get-Content -Raw $file.FullName | ConvertFrom-Json -ErrorAction Stop
            if ($data -is [System.Array]) {
                foreach ($entry in $data) { $findings.Add($entry) }
            } else {
                $findings.Add($data)
            }
        } catch {
            Write-Warning "Could not parse AzGovViz output $($file.Name): $(Remove-Credentials -Text ([string]$_))"
        }
    }
    foreach ($csvFinding in (Import-AzGovVizCsvFindings -OutputPath $OutputPath)) {
        $findings.Add($csvFinding)
    }

    return [PSCustomObject]@{
        Source   = 'azgovviz'
        Status   = 'Success'
        Message  = ''
        Findings = @($findings)
    }
} catch {
    Write-Warning "AzGovViz run failed: $(Remove-Credentials -Text ([string]$_))"
    return [PSCustomObject]@{
        Source   = 'azgovviz'
        Status   = 'Failed'
        Message  = Remove-Credentials -Text ([string]$_)
        Findings = @()
    }
}
