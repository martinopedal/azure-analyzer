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
$missingToolPath = Join-Path $PSScriptRoot 'shared' 'MissingTool.ps1'
if (Test-Path $missingToolPath) { . $missingToolPath }
$errorsPath = Join-Path $PSScriptRoot 'shared' 'Errors.ps1'
if (Test-Path $errorsPath) { . $errorsPath }
if (-not (Get-Command Write-MissingToolNotice -ErrorAction SilentlyContinue)) {
    function Write-MissingToolNotice { param([string]$Tool, [string]$Message) Write-Warning $Message }
}
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param([string]$Text) return $Text }
}
if (-not (Get-Command New-FindingError -ErrorAction SilentlyContinue)) {
    function New-FindingError { param([string]$Source,[string]$Category,[string]$Reason,[string]$Remediation,[string]$Details) return [pscustomobject]@{ Source=$Source; Category=$Category; Reason=$Reason; Remediation=$Remediation; Details=$Details } }
}
if (-not (Get-Command Format-FindingErrorMessage -ErrorAction SilentlyContinue)) {
    function Format-FindingErrorMessage {
        param([Parameter(Mandatory)]$FindingError)
        $line = "[{0}] {1}: {2}" -f $FindingError.Source, $FindingError.Category, $FindingError.Reason
        if ($FindingError.Remediation) { $line += " Action: $($FindingError.Remediation)" }
        return $line
    }
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

function ConvertTo-DelimitedList {
    param ([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    return @(
        $Value -split '[,;|]' |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function ConvertTo-UniqueStringArray {
    param ([object[]]$Items)

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $values = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($Items)) {
        if ($null -eq $item) { continue }
        $text = [string]$item
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $trimmed = $text.Trim()
        if ($seen.Add($trimmed)) {
            $values.Add($trimmed) | Out-Null
        }
    }
    return @($values)
}

function Get-AzGovVizPillar {
    param (
        [string]$Category,
        [string]$Title
    )

    $normalizedCategory = ($Category ?? '').Trim().ToLowerInvariant()
    $normalizedTitle = ($Title ?? '').Trim().ToLowerInvariant()

    if ($normalizedCategory -match '^(policy|identity)$') { return 'Security' }
    if ($normalizedCategory -match '^(cost|costoptimization|finops)$') { return 'Cost' }
    if ($normalizedTitle -match 'orphaned') { return 'Cost' }
    return 'Operational Excellence'
}

function ConvertTo-BaselineTag {
    param ([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    $slug = ($Name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) { return '' }
    return "initiative:$slug"
}

function Get-AzGovVizFrameworks {
    param ([psobject]$FindingLike)

    if ($FindingLike.PSObject.Properties['Frameworks'] -and @($FindingLike.Frameworks).Count -gt 0) {
        $normalized = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($framework in @($FindingLike.Frameworks)) {
            if ($null -eq $framework) { continue }
            $name = ''
            $controls = @()
            if ($framework -is [System.Collections.IDictionary]) {
                $name = [string]($framework['Name'] ?? $framework['name'] ?? '')
                $controls = @($framework['Controls'] ?? $framework['controls'] ?? @())
            } else {
                $nameProp = $framework.PSObject.Properties['Name']
                if ($null -eq $nameProp) { $nameProp = $framework.PSObject.Properties['name'] }
                $controlsProp = $framework.PSObject.Properties['Controls']
                if ($null -eq $controlsProp) { $controlsProp = $framework.PSObject.Properties['controls'] }
                $name = if ($null -ne $nameProp) { [string]$nameProp.Value } else { '' }
                $controls = if ($null -ne $controlsProp) { @($controlsProp.Value) } else { @() }
            }
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($name -ieq 'MCSB') { $name = 'CAF' }
            $normalized.Add(@{
                    Name     = $name
                    Controls = @(ConvertTo-UniqueStringArray -Items $controls)
                }) | Out-Null
        }
        return @($normalized)
    }

    $policySetId = Get-RowValue -Row $FindingLike -Names @('PolicySetDefinitionId', 'PolicySetId', 'policySetId', 'policySetDefinitionId')
    $mcsbRaw = Get-RowValue -Row $FindingLike -Names @('MCSBControls', 'McsbControls', 'MCSBControlIds', 'ControlIds')
    $mcsbControls = ConvertTo-DelimitedList -Value $mcsbRaw

    $frameworks = [System.Collections.Generic.List[hashtable]]::new()
    if ($policySetId) {
        $frameworks.Add(@{
                Name     = 'ALZ'
                Controls = @($policySetId)
            })
    }
    if (@($mcsbControls).Count -gt 0) {
        $frameworks.Add(@{
                Name     = 'CAF'
                Controls = @($mcsbControls)
            })
    }

    return @($frameworks)
}

function Get-AzGovVizBaselineTags {
    param ([psobject]$FindingLike)

    $tags = [System.Collections.Generic.List[string]]::new()

    if ($FindingLike.PSObject.Properties['BaselineTags'] -and @($FindingLike.BaselineTags).Count -gt 0) {
        foreach ($existingTag in @($FindingLike.BaselineTags)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$existingTag)) {
                $tags.Add(([string]$existingTag).Trim()) | Out-Null
            }
        }
    }

    $initiativeName = Get-RowValue -Row $FindingLike -Names @(
        'PolicySetDefinitionName',
        'PolicyInitiativeName',
        'PolicyAssignmentName',
        'InitiativeName'
    )

    foreach ($name in (ConvertTo-DelimitedList -Value $initiativeName)) {
        $tag = ConvertTo-BaselineTag -Name $name
        if ($tag) { $tags.Add($tag) }
    }

    $category = Get-RowValue -Row $FindingLike -Names @('Category', 'category')
    if (-not [string]::IsNullOrWhiteSpace($category)) {
        $categoryTag = ConvertTo-BaselineTag -Name "category-$category"
        if ($categoryTag) { $tags.Add($categoryTag) | Out-Null }
    }

    return @(ConvertTo-UniqueStringArray -Items @($tags))
}

function Get-AzGovVizImpact {
    param (
        [string]$Severity,
        [string]$Category
    )

    $severityKey = ($Severity ?? '').Trim().ToLowerInvariant()
    switch ($severityKey) {
        'critical' { return 'High' }
        'high' { return 'High' }
        'medium' { return 'Medium' }
        'low' { return 'Low' }
        'info' { return 'Low' }
    }

    $categoryKey = ($Category ?? '').Trim().ToLowerInvariant()
    if ($categoryKey -match '^(policy|identity)$') { return 'High' }
    if ($categoryKey -match '^(cost|costoptimization|finops)$') { return 'Medium' }
    return 'Medium'
}

function Get-AzGovVizEffort {
    param ([string]$Category)

    $categoryKey = ($Category ?? '').Trim().ToLowerInvariant()
    if ($categoryKey -eq 'operations') { return 'Medium' }
    if ($categoryKey -eq 'identity') { return 'High' }
    if ($categoryKey -eq 'policy') { return 'Medium' }
    if ($categoryKey -match '^(cost|costoptimization|finops)$') { return 'Low' }
    return 'Low'
}

function Get-AzGovVizRemediationSnippets {
    param (
        [string]$Remediation,
        [string]$Category
    )

    $content = $Remediation
    if ([string]::IsNullOrWhiteSpace($content)) {
        $content = switch -Regex (($Category ?? '').Trim().ToLowerInvariant()) {
            '^policy$' { 'Review policy assignment, initiative scope, and non-compliant resources in AzGovViz output and apply corrective policy actions.' }
            '^identity$' { 'Review privileged role assignments and reduce standing access using least privilege.' }
            '^operations$' { 'Enable required diagnostics settings and route telemetry to an approved destination.' }
            '^cost|costoptimization|finops$' { 'Review cost optimization opportunities and remove or right-size orphaned assets.' }
            default { 'Review the finding in AzGovViz output and apply the recommended governance control.' }
        }
    }

    return @(
        @{
            language = 'text'
            code     = $content.Trim()
        }
    )
}

function Get-AzGovVizDeepLink {
    param (
        [string]$Category,
        [string]$ResourceId,
        [string]$Scope,
        [string]$ManagementGroupId,
        [string]$ManagementGroupResourceId,
        [string]$PolicySetId,
        [string]$ReportUri
    )

    $normalizedCategory = ($Category ?? '').Trim().ToLowerInvariant()
    if ($normalizedCategory -eq 'policy') {
        if (-not [string]::IsNullOrWhiteSpace($PolicySetId) -and $PolicySetId -match '/policySetDefinitions/([^/\?]+)') {
            $initiativeName = $Matches[1]
            return "https://www.azadvertizer.net/azpolicyinitiativesadvertizer/$initiativeName.html"
        }
        if (-not [string]::IsNullOrWhiteSpace($ReportUri)) {
            return "$ReportUri#policy"
        }
        $effectiveScope = if ($Scope) { $Scope } elseif ($ResourceId) { $ResourceId } elseif ($ManagementGroupResourceId) { $ManagementGroupResourceId } elseif ($ManagementGroupId) { "/providers/Microsoft.Management/managementGroups/$ManagementGroupId" } else { '' }
        if ($effectiveScope) {
            return "https://portal.azure.com/#view/Microsoft_Azure_Policy/PolicyMenuBlade/~/Compliance?scope=$([uri]::EscapeDataString($effectiveScope))"
        }
        return 'https://github.com/JulianHayward/Azure-MG-Sub-Governance-Reporting'
    }

    if ($ResourceId) {
        return "https://portal.azure.com/#@/resource$($ResourceId)/overview"
    }
    if ($ManagementGroupResourceId) {
        return "https://portal.azure.com/#@/resource$($ManagementGroupResourceId)/overview"
    }
    if ($ManagementGroupId) {
        return "https://portal.azure.com/#@/resource/providers/Microsoft.Management/managementGroups/$ManagementGroupId/overview"
    }

    if (-not [string]::IsNullOrWhiteSpace($ReportUri)) {
        return "$ReportUri#governance"
    }

    return ''
}

function Get-AzGovVizEvidenceUris {
    param (
        [string]$ReportUri,
        [string]$Category
    )

    if ([string]::IsNullOrWhiteSpace($ReportUri)) { return @() }
    $anchor = switch -Regex (($Category ?? '').Trim().ToLowerInvariant()) {
        '^policy$' { '#policy' }
        '^identity$' { '#rbac' }
        '^cost|costoptimization|finops$' { '#cost' }
        '^operations$' { '#operations' }
        default { '#governance' }
    }
    return @("$ReportUri$anchor")
}

function Resolve-AzGovVizReportUri {
    param ([string]$OutputPath)

    $report = Get-ChildItem -Path $OutputPath -Filter '*.html' -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if (-not $report) { return '' }
    return ([System.Uri]::new($report.FullName)).AbsoluteUri
}

function Get-AzGovVizToolVersion {
    param ([string]$ScriptPath)

    try {
        $content = Get-Content -Path $ScriptPath -Raw -ErrorAction Stop
        foreach ($pattern in @(
                '(?im)^\s*\$script:Version\s*=\s*[''"](?<v>[^''"]+)[''"]',
                '(?im)^\s*Version\s*[:=]\s*[''"](?<v>[^''"]+)[''"]',
                '(?im)^\s*#\s*Version[:\s]+(?<v>\d+\.\d+(?:\.\d+)?)'
            )) {
            if ($content -match $pattern) {
                return $Matches['v']
            }
        }
    } catch {
        Write-Verbose "Could not infer AzGovViz version from script: $(Remove-Credentials -Text ([string]$_))"
    }

    return 'unknown'
}

function New-AzGovVizFinding {
    param (
        [Parameter(Mandatory)]
        [object]$FindingLike,
        [string]$ManagementGroupId,
        [string]$ToolVersion,
        [string]$ReportUri
    )

    $props = @{}
    foreach ($p in $FindingLike.PSObject.Properties) {
        $props[$p.Name] = $p.Value
    }

    $category = if ($props.ContainsKey('Category')) { [string]$props['Category'] } else { 'Governance' }
    $title = if ($props.ContainsKey('Title')) { [string]$props['Title'] } else { '' }
    $resourceId = if ($props.ContainsKey('ResourceId')) { [string]$props['ResourceId'] } else { '' }
    $scope = if ($props.ContainsKey('Scope')) { [string]$props['Scope'] } else { '' }
    $policySetId = if ($props.ContainsKey('PolicySetId')) { [string]$props['PolicySetId'] } elseif ($props.ContainsKey('PolicySetDefinitionId')) { [string]$props['PolicySetDefinitionId'] } else { '' }
    $managementGroupResourceId = if ($props.ContainsKey('ManagementGroupResourceId')) {
        [string]$props['ManagementGroupResourceId']
    } elseif ($ManagementGroupId) {
        "/providers/Microsoft.Management/managementGroups/$ManagementGroupId"
    } else {
        ''
    }

    $props['Source'] = 'azgovviz'
    if (-not $props.ContainsKey('SchemaVersion') -or [string]::IsNullOrWhiteSpace([string]$props['SchemaVersion'])) {
        $props['SchemaVersion'] = '1.0'
    }
    if (-not $props.ContainsKey('Category') -or [string]::IsNullOrWhiteSpace([string]$props['Category'])) {
        $props['Category'] = 'Governance'
    }
    if (-not $props.ContainsKey('Pillar') -or [string]::IsNullOrWhiteSpace([string]$props['Pillar'])) {
        $props['Pillar'] = Get-AzGovVizPillar -Category $category -Title $title
    }
    try {
        if (-not $props.ContainsKey('Frameworks') -or @($props['Frameworks']).Count -eq 0) {
            $props['Frameworks'] = @(Get-AzGovVizFrameworks -FindingLike ([pscustomobject]$props))
        }
    } catch {
        $props['Frameworks'] = @()
    }
    try {
        if (-not $props.ContainsKey('BaselineTags') -or @($props['BaselineTags']).Count -eq 0) {
            $props['BaselineTags'] = @(Get-AzGovVizBaselineTags -FindingLike ([pscustomobject]$props))
        }
    } catch {
        $props['BaselineTags'] = @()
    }
    if (-not $props.ContainsKey('ToolVersion') -or [string]::IsNullOrWhiteSpace([string]$props['ToolVersion'])) {
        $props['ToolVersion'] = $ToolVersion
    }
    if ($ManagementGroupId -and (-not $props.ContainsKey('ManagementGroupId') -or [string]::IsNullOrWhiteSpace([string]$props['ManagementGroupId']))) {
        $props['ManagementGroupId'] = $ManagementGroupId
    }
    if ($managementGroupResourceId -and (-not $props.ContainsKey('ManagementGroupResourceId') -or [string]::IsNullOrWhiteSpace([string]$props['ManagementGroupResourceId']))) {
        $props['ManagementGroupResourceId'] = $managementGroupResourceId
    }
    if (-not $props.ContainsKey('DeepLinkUrl') -or [string]::IsNullOrWhiteSpace([string]$props['DeepLinkUrl'])) {
        $props['DeepLinkUrl'] = Get-AzGovVizDeepLink -Category $category -ResourceId $resourceId -Scope $scope -ManagementGroupId $ManagementGroupId -ManagementGroupResourceId $managementGroupResourceId -PolicySetId $policySetId -ReportUri $ReportUri
    }
    if (-not $props.ContainsKey('EvidenceUris') -or @($props['EvidenceUris']).Count -eq 0) {
        $props['EvidenceUris'] = @(Get-AzGovVizEvidenceUris -ReportUri $ReportUri -Category $category)
    }
    if (-not $props.ContainsKey('Impact') -or [string]::IsNullOrWhiteSpace([string]$props['Impact'])) {
        $props['Impact'] = Get-AzGovVizImpact -Severity ([string]$props['Severity']) -Category $category
    }
    if (-not $props.ContainsKey('Effort') -or [string]::IsNullOrWhiteSpace([string]$props['Effort'])) {
        $props['Effort'] = Get-AzGovVizEffort -Category $category
    }
    if (-not $props.ContainsKey('RemediationSnippets') -or @($props['RemediationSnippets']).Count -eq 0) {
        $props['RemediationSnippets'] = @(Get-AzGovVizRemediationSnippets -Remediation ([string]($props['Remediation'] ?? '')) -Category $category)
    }

    return [pscustomobject]$props
}

function Import-AzGovVizCsvFindings {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $OutputPath,
        [string] $ManagementGroupId,
        [string] $ToolVersion,
        [string] $ReportUri
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
                    $policySetId = Get-RowValue -Row $row -Names @('PolicySetDefinitionId', 'PolicySetId', 'policySetId')
                    $policyInitiativeName = Get-RowValue -Row $row -Names @('PolicySetDefinitionName', 'PolicyInitiativeName', 'initiativeName')
                    $mcsbControls = Get-RowValue -Row $row -Names @('MCSBControls', 'McsbControls', 'MCSBControlIds')
                    $resourceId = Get-RowValue -Row $row -Names @('ResourceId', 'resourceId', 'ResourceID', 'Scope', 'scope')
                    $scope = Get-RowValue -Row $row -Names @('Scope', 'scope')
                    $stateText = if ($complianceState) { $complianceState } else { 'Unknown' }
                    $isCompliant = ($complianceState -eq 'Compliant')
                    if ($isCompliant) { continue }
                    $titleSuffix = if ($policyAssignment) { ": $policyAssignment" } else { '' }
                    $findings.Add((New-AzGovVizFinding -FindingLike ([pscustomobject]@{
                             Source      = 'azgovviz'
                             Category    = 'Policy'
                             Title       = "Policy compliance state$titleSuffix"
                             Compliant   = $false
                             Severity    = Get-PolicyEffectSeverity -Effect $effect
                             Detail      = "ComplianceState=$stateText; Effect=$effect; Scope=$scope"
                             ResourceId  = $resourceId
                             Scope       = $scope
                             PolicySetId = $policySetId
                             PolicySetDefinitionName = $policyInitiativeName
                             MCSBControls = $mcsbControls
                             SchemaVersion = '1.0'
                         }) -ManagementGroupId $ManagementGroupId -ToolVersion $ToolVersion -ReportUri $ReportUri))
                }
            }
            'roleassignments' {
                foreach ($row in $rows) {
                    $principalId = Get-RowValue -Row $row -Names @('RoleAssignmentIdentityObjectId', 'ObjectId', 'PrincipalId', 'principalId', 'AssigneeObjectId')
                    if (-not $principalId) { continue }

                    $roleName = Get-RowValue -Row $row -Names @('RoleDefinitionName', 'RoleName', 'roleDefinitionName')
                    $scope = Get-RowValue -Row $row -Names @('RoleAssignmentScope', 'Scope', 'scope')
                    $scopeType = Get-RowValue -Row $row -Names @('RoleAssignmentScopeType', 'ScopeType', 'scopeType')
                    $principalType = Get-RowValue -Row $row -Names @('RoleAssignmentIdentityObjectType', 'PrincipalType', 'principalType', 'ObjectType')
                    $isPrivilegedRole = $roleName -match '^(Owner|Contributor|User Access Administrator)$'
                    $isBroadScopeType = $scopeType -match '^(tenant|managementgroup|subscription)$'
                    $isBroadScopePath = $scope -match '^/subscriptions/[^/]+$' -or $scope -match '^/providers/microsoft\.management/managementgroups/'
                    $isBroadScope = $isBroadScopeType -or $isBroadScopePath
                    $isCompliant = -not ($isPrivilegedRole -and $isBroadScope)
                    if ($isCompliant) { continue }
                    $severity = 'High'
                    $resourceId = if ($scope) { $scope } else { '' }

                    $findings.Add((New-AzGovVizFinding -FindingLike ([pscustomobject]@{
                             Source        = 'azgovviz'
                             Category      = 'Identity'
                             Title         = "Role assignment: $roleName"
                            Compliant     = $false
                            Severity      = $severity
                            Detail        = "PrincipalType=$principalType; Scope=$scope; ScopeType=$scopeType"
                            ResourceId    = $resourceId
                             PrincipalId   = $principalId
                             PrincipalType = $principalType
                             Scope         = $scope
                             SchemaVersion = '1.0'
                         }) -ManagementGroupId $ManagementGroupId -ToolVersion $ToolVersion -ReportUri $ReportUri))
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

                    $findings.Add((New-AzGovVizFinding -FindingLike ([pscustomobject]@{
                             Source        = 'azgovviz'
                             Category      = 'Operations'
                            Title         = 'Resource diagnostics settings not configured'
                            Compliant     = $false
                            Severity      = 'Medium'
                            Detail        = "DiagnosticsCapable=$capable; DiagnosticsConfigured=$configured"
                             ResourceId    = $resourceId
                             Remediation   = 'Enable diagnostic settings to route logs and metrics to an approved destination.'
                             SchemaVersion = '1.0'
                         }) -ManagementGroupId $ManagementGroupId -ToolVersion $ToolVersion -ReportUri $ReportUri))
                }
            }
            'resourceswithouttags' {
                foreach ($row in $rows) {
                    $resourceId = Get-RowValue -Row $row -Names @('ResourceId', 'resourceId', 'ResourceID')
                    if (-not $resourceId) { continue }
                    $missingTags = Get-RowValue -Row $row -Names @('MissingTags', 'missingTags', 'TagNames')

                    $findings.Add((New-AzGovVizFinding -FindingLike ([pscustomobject]@{
                             Source        = 'azgovviz'
                             Category      = 'Governance'
                            Title         = 'Resource missing required tags'
                            Compliant     = $false
                            Severity      = 'Low'
                            Detail        = if ($missingTags) { "MissingTags=$missingTags" } else { 'Missing one or more required tags.' }
                             ResourceId    = $resourceId
                             Remediation   = 'Apply required governance tags according to your tagging policy.'
                             SchemaVersion = '1.0'
                         }) -ManagementGroupId $ManagementGroupId -ToolVersion $ToolVersion -ReportUri $ReportUri))
                }
            }
            'orphanedresources' {
                foreach ($row in $rows) {
                    $resourceId = Get-RowValue -Row $row -Names @('ResourceId', 'resourceId', 'ResourceID')
                    if (-not $resourceId) { continue }
                    $monthlyCost = Get-RowValue -Row $row -Names @('EstimatedMonthlyCost', 'MonthlyCost', 'Cost')
                    $costText = if ($monthlyCost) { "EstimatedMonthlyCost=$monthlyCost" } else { 'Potential cost waste from orphaned resource.' }

                    $findings.Add((New-AzGovVizFinding -FindingLike ([pscustomobject]@{
                                Source        = 'azgovviz'
                                Category      = 'Cost'
                                Title         = 'Orphaned resource detected'
                                Compliant     = $false
                                Severity      = 'Medium'
                                Detail        = $costText
                                ResourceId    = $resourceId
                                Remediation   = 'Remove the orphaned resource or attach it to an active workload.'
                                SchemaVersion = '1.0'
                            }) -ManagementGroupId $ManagementGroupId -ToolVersion $ToolVersion -ReportUri $ReportUri))
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
    Write-MissingToolNotice -Tool 'azgovviz' -Message "AzGovViz (AzGovVizParallel.ps1) not found. Skipping. Clone from https://github.com/JulianHayward/Azure-MG-Sub-Governance-Reporting"
    return [PSCustomObject]@{
        Source   = 'azgovviz'
        Status   = 'Skipped'
        Message  = 'AzGovVizParallel.ps1 not found'
        Findings = @()
    }    Errors   = @()
$3
}

if (-not (Test-Path $OutputPath)) {
    $null = New-Item -ItemType Directory -Path $OutputPath -Force
}

try {
    Write-Verbose "Running AzGovViz for management group: $ManagementGroupId"
    $toolVersion = Get-AzGovVizToolVersion -ScriptPath $azGovVizScript
    $runAzGovViz = {
        $result = Invoke-WithTimeout -Command 'pwsh' -Arguments @(
            '-File', $azGovVizScript,
            '-ManagementGroupId', $ManagementGroupId,
            '-OutputPath', $OutputPath,
            '-AzureDevOpsWikiAsCode', 'False',
            '-HierarchyTreeOnly', 'False'
        ) -TimeoutSec 300
        if ($result.ExitCode -ne 0) {
            throw (Format-FindingErrorMessage (New-FindingError `
                -Source 'wrapper:azgovviz' `
                -Category 'UnexpectedFailure' `
                -Reason "AzGovViz exited with code $($result.ExitCode)." `
                -Remediation 'Review AzGovViz CLI output and ensure required modules are installed; rerun.' `
                -Details (Remove-Credentials -Text ([string]$result.Output))))
        }
    }
    Invoke-WithRetry -ScriptBlock $runAzGovViz -MaxAttempts 3 -InitialDelaySeconds 2 -MaxDelaySeconds 10 | Out-Null

    $reportUri = Resolve-AzGovVizReportUri -OutputPath $OutputPath
    $summaryFiles = Get-ChildItem -Path $OutputPath -Filter '*Summary*.json' -Recurse -ErrorAction SilentlyContinue
    $findings = [System.Collections.Generic.List[psobject]]::new()
    foreach ($file in $summaryFiles) {
        try {
            $data = Get-Content -Raw $file.FullName | ConvertFrom-Json -ErrorAction Stop
            if ($data -is [System.Array]) {
                foreach ($entry in $data) {
                    $findings.Add((New-AzGovVizFinding -FindingLike $entry -ManagementGroupId $ManagementGroupId -ToolVersion $toolVersion -ReportUri $reportUri))
                }
            } else {
                $findings.Add((New-AzGovVizFinding -FindingLike $data -ManagementGroupId $ManagementGroupId -ToolVersion $toolVersion -ReportUri $reportUri))
            }
        } catch {
            Write-Warning "Could not parse AzGovViz output $($file.Name): $(Remove-Credentials -Text ([string]$_))"
        }
    }
    foreach ($csvFinding in (Import-AzGovVizCsvFindings -OutputPath $OutputPath -ManagementGroupId $ManagementGroupId -ToolVersion $toolVersion -ReportUri $reportUri)) {
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
    }    Errors   = @()
$3
}
