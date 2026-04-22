#Requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for Maester — Entra ID / identity security posture assessment.
.DESCRIPTION
    Installs/imports the Maester module if needed, verifies a Microsoft Graph
    connection exists, runs Invoke-Maester -PassThru -Quiet, and returns
    findings as PSObjects. Gracefully degrades if Maester is not available,
    Graph is not connected, or the assessment fails.
    Requires: Connect-MgGraph -Scopes (Get-MtGraphScope)
.EXAMPLE
    .\Invoke-Maester.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sanitizePath = Join-Path $PSScriptRoot 'shared' 'Sanitize.ps1'
if (Test-Path $sanitizePath) { . $sanitizePath }
$missingToolPath = Join-Path $PSScriptRoot 'shared' 'MissingTool.ps1'
if (Test-Path $missingToolPath) { . $missingToolPath }
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param([string]$Text) return $Text }
}
if (-not (Get-Command Write-MissingToolNotice -ErrorAction SilentlyContinue)) {
    function Write-MissingToolNotice { param([string]$Tool, [string]$Message) Write-Warning $Message }
}

function ConvertTo-MaesterStringArray {
    param([object] $Value)
    $values = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($Value)) {
        if ($null -eq $item) { continue }
        if ($item -is [string]) {
            if (-not [string]::IsNullOrWhiteSpace($item)) { $values.Add($item.Trim()) | Out-Null }
            continue
        }
        if ($item -is [System.Collections.IDictionary]) {
            foreach ($candidate in 'Id', 'ID', 'id', 'AppId', 'appId', 'Name', 'name') {
                if ($item.Contains($candidate) -and -not [string]::IsNullOrWhiteSpace([string]$item[$candidate])) {
                    $values.Add(([string]$item[$candidate]).Trim()) | Out-Null
                    break
                }
            }
            continue
        }
        if ($item -is [System.Collections.IEnumerable] -and $item -isnot [string]) {
            foreach ($nested in @(ConvertTo-MaesterStringArray -Value $item)) {
                if (-not [string]::IsNullOrWhiteSpace($nested)) { $values.Add($nested) | Out-Null }
            }
            continue
        }
        $candidate = [string]$item
        if (-not [string]::IsNullOrWhiteSpace($candidate)) { $values.Add($candidate.Trim()) | Out-Null }
    }
    return @($values | Select-Object -Unique)
}

function Get-MaesterPropertyValue {
    param(
        [Parameter(Mandatory)]
        [object] $Object,
        [Parameter(Mandatory)]
        [string[]] $Candidates
    )
    foreach ($candidate in $Candidates) {
        if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($candidate) -and $null -ne $Object[$candidate]) {
            return $Object[$candidate]
        }
        $property = $Object.PSObject.Properties[$candidate]
        if ($property -and $null -ne $property.Value) {
            return $property.Value
        }
    }
    return $null
}

function Get-MaesterToolVersion {
    $module = Get-Module -Name Maester -ListAvailable -ErrorAction SilentlyContinue |
        Sort-Object -Property Version -Descending |
        Select-Object -First 1
    if ($module -and $module.Version) { return [string]$module.Version }
    return ''
}

function Get-MaesterTestId {
    param([object] $Test)
    foreach ($candidate in 'TestId', 'Id', 'ID') {
        $value = Get-MaesterPropertyValue -Object $Test -Candidates @($candidate)
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) { return [string]$value }
    }
    $name = [string](Get-MaesterPropertyValue -Object $Test -Candidates @('Name', 'ExpandedName'))
    if ([string]::IsNullOrWhiteSpace($name)) { return [guid]::NewGuid().ToString() }
    return ($name -replace '[^A-Za-z0-9._-]', '-').Trim('-')
}

function Get-MaesterTagMetadata {
    param([string[]] $Tags)
    $frameworks = [System.Collections.Generic.List[hashtable]]::new()
    $baselineTags = [System.Collections.Generic.List[string]]::new()
    $mitreTactics = [System.Collections.Generic.List[string]]::new()
    $mitreTechniques = [System.Collections.Generic.List[string]]::new()
    $seenFrameworks = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($tagRaw in @($Tags)) {
        if ([string]::IsNullOrWhiteSpace($tagRaw)) { continue }
        $tag = $tagRaw.Trim()

        if ($tag -match '^(?i)(?:mitre[-_:\/]?)?(TA\d{4})$') {
            $mitreTactics.Add($Matches[1].ToUpperInvariant()) | Out-Null
            continue
        }
        if ($tag -match '^(?i)(?:mitre[-_:\/]?)?(T\d{4}(?:\.\d{3})?)$') {
            $mitreTechniques.Add($Matches[1].ToUpperInvariant()) | Out-Null
            continue
        }

        $frameworkName = $null
        if ($tag -match '^(?i)CIS-MS365-[A-Za-z0-9.\-]+$') {
            $frameworkName = 'CIS Microsoft 365'
        } elseif ($tag -match '^(?i)NIST(?:-800-53)?-[A-Za-z0-9.\-]+$') {
            $frameworkName = 'NIST 800-53'
        } elseif ($tag -match '^(?i)EIDSCA-[A-Za-z0-9.\-]+$') {
            $frameworkName = 'EIDSCA'
        }

        if ($frameworkName) {
            $baselineTags.Add($tag) | Out-Null
            $key = "$frameworkName|$tag"
            if ($seenFrameworks.Add($key)) {
                $frameworks.Add([ordered]@{
                        kind      = $frameworkName
                        Name      = $frameworkName
                        controlId = $tag
                        Controls  = @($tag)
                    }) | Out-Null
            }
        }
    }

    [PSCustomObject]@{
        Frameworks      = @($frameworks)
        BaselineTags    = @($baselineTags | Select-Object -Unique)
        MitreTactics    = @($mitreTactics | Select-Object -Unique)
        MitreTechniques = @($mitreTechniques | Select-Object -Unique)
    }
}

function Get-MaesterRemediationSnippets {
    param([string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $snippets = [System.Collections.Generic.List[hashtable]]::new()
    $matches = [regex]::Matches($Text, '(?ms)```(?<language>[^\r\n`]*)\r?\n(?<code>.*?)```')
    foreach ($match in $matches) {
        $code = [string]$match.Groups['code'].Value
        if ([string]::IsNullOrWhiteSpace($code)) { continue }
        $language = [string]$match.Groups['language'].Value
        if ([string]::IsNullOrWhiteSpace($language)) { $language = 'text' }
        $snippets.Add(@{
                language = $language.Trim().ToLowerInvariant()
                code     = $code.Trim()
            }) | Out-Null
    }
    if ($snippets.Count -eq 0) {
        $snippets.Add(@{ language = 'text'; code = $Text.Trim() }) | Out-Null
    }
    return @($snippets)
}

# Check Maester module is available (centralized Install-Prerequisites handles installation)
if (-not (Get-Module -ListAvailable -Name Maester)) {
    Write-MissingToolNotice -Tool 'maester' -Message "Maester module not found. Install with: Install-Module Maester -Scope CurrentUser"
    return [PSCustomObject]@{ SchemaVersion = '1.0'; Source = 'maester'; Status = 'Skipped'; Message = 'Maester module not installed. Run: Install-Module Maester -Scope CurrentUser'; Findings = @() }
}

Import-Module Maester -ErrorAction SilentlyContinue
if (-not (Get-Command Invoke-Maester -ErrorAction SilentlyContinue)) {
    Write-MissingToolNotice -Tool 'maester' -Message "Maester module loaded but Invoke-Maester not found. Returning empty result."
    return [PSCustomObject]@{ SchemaVersion = '1.0'; Source = 'maester'; Status = 'Skipped'; Message = 'Invoke-Maester command not available'; Findings = @() }
}

# Verify Microsoft Graph connection
if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue)) {
    Write-MissingToolNotice -Tool 'maester' -Message "Microsoft Graph SDK command Get-MgContext not found. Install Microsoft.Graph and connect before using Maester."
    return [PSCustomObject]@{ SchemaVersion = '1.0'; Source = 'maester'; Status = 'Skipped'; Message = 'Get-MgContext command not available. Install Microsoft.Graph and run Connect-MgGraph.'; Findings = @() }
}

$mgContext = Get-MgContext -ErrorAction SilentlyContinue
if (-not $mgContext) {
    Write-Warning "No Microsoft Graph connection found. Run 'Connect-MgGraph -Scopes (Get-MtGraphScope)' before using Maester. Returning empty result."
    return [PSCustomObject]@{ SchemaVersion = '1.0'; Source = 'maester'; Status = 'Skipped'; Message = 'No Microsoft Graph connection. Run: Connect-MgGraph -Scopes (Get-MtGraphScope)'; Findings = @() }
}

# Run Maester assessment — returns a Pester TestResultContainer
try {
    $container = Invoke-Maester -PassThru -Quiet -ErrorAction Stop
} catch {
    Write-Warning "Maester assessment failed: $(Remove-Credentials -Text ([string]$_)). Returning empty result."
    return [PSCustomObject]@{ SchemaVersion = '1.0'; Source = 'maester'; Status = 'Failed'; Message = (Remove-Credentials -Text ([string]$_)); Findings = @() }
}

if (-not $container -or -not $container.Result) {
    Write-Warning "Maester returned no test results."
    return [PSCustomObject]@{ SchemaVersion = '1.0'; Source = 'maester'; Status = 'Failed'; Message = 'No test results returned'; Findings = @() }
}

# Map Pester TestResult objects to flat findings
$findings = [System.Collections.Generic.List[PSCustomObject]]::new()
$toolVersion = Get-MaesterToolVersion

foreach ($test in $container.Result) {
    $testId = Get-MaesterTestId -Test $test
    $tags = ConvertTo-MaesterStringArray -Value (Get-MaesterPropertyValue -Object $test -Candidates @('Tag', 'Tags'))
    $tagMetadata = Get-MaesterTagMetadata -Tags $tags
    $deepLinkUrl = if (-not [string]::IsNullOrWhiteSpace($testId)) {
        "https://maester.dev/docs/tests/$testId"
    } else {
        ''
    }

    # Derive severity from tags using word boundaries so tags like
    # "criticality" or "highlight" don't bleed into Critical/High.
    $severity = 'Medium'
    if ($tags) {
        $tagStr = ($tags -join ' ').ToLowerInvariant()
        if     ($tagStr -match '\bcritical\b') { $severity = 'Critical' }
        elseif ($tagStr -match '\bhigh\b')     { $severity = 'High' }
        elseif ($tagStr -match '\blow\b')      { $severity = 'Low' }
        elseif ($tagStr -match '\b(info|informational)\b') { $severity = 'Info' }
    }

    # Map Result: Passed/Skipped/NotRun → compliant, Failed → non-compliant
    $compliant = $test.Result -ne 'Failed'

    # Extract detail from ErrorRecord if present
    $detail = ''
    $errorRecord = Get-MaesterPropertyValue -Object $test -Candidates @('ErrorRecord')
    if ($errorRecord) {
        $detail = ($errorRecord | ForEach-Object { $_.ToString() }) -join '; '
    } else {
        $detail = [string](Get-MaesterPropertyValue -Object $test -Candidates @('FailureMessage', 'ErrorMessage', 'Detail', 'ResultDetail'))
    }
    if ($null -eq $detail) { $detail = '' }

    # Extract category from parent Block name
    $category = 'Identity'
    $block = Get-MaesterPropertyValue -Object $test -Candidates @('Block')
    if ($block -and $block.PSObject.Properties['Name'] -and $block.Name) {
        $category = $block.Name
    }

    $learnMore = [string](Get-MaesterPropertyValue -Object $test -Candidates @('LearnMoreUrl', 'LearnMore', 'DocumentationUrl', 'DocsUrl', 'ReferenceUrl'))
    $remediation = [string](Get-MaesterPropertyValue -Object $test -Candidates @('HowToFix', 'Fix', 'Remediation', 'Recommendation'))
    if ($null -eq $remediation) { $remediation = '' }

    $evidenceUris = [System.Collections.Generic.List[string]]::new()
    foreach ($uri in ConvertTo-MaesterStringArray -Value (Get-MaesterPropertyValue -Object $test -Candidates @('EvidenceUris', 'EvidenceUri', 'EvidenceLinks', 'Evidence'))) {
        if ($uri -match '^(?i)https://') { $evidenceUris.Add($uri) | Out-Null }
    }
    foreach ($uri in ConvertTo-MaesterStringArray -Value (Get-MaesterPropertyValue -Object $test -Candidates @('SourceUri', 'SourceUrl', 'TestSourceUri', 'TestSourceUrl', 'Source'))) {
        if ($uri -match '^(?i)https://') { $evidenceUris.Add($uri) | Out-Null }
    }
    if (-not [string]::IsNullOrWhiteSpace($learnMore)) { $evidenceUris.Add($learnMore) | Out-Null }
    if (-not [string]::IsNullOrWhiteSpace($deepLinkUrl)) { $evidenceUris.Add($deepLinkUrl) | Out-Null }
    $evidenceUrisOut = @($evidenceUris | Select-Object -Unique)

    $entityRefs = [System.Collections.Generic.List[string]]::new()
    if ($mgContext.TenantId) { $entityRefs.Add([string]$mgContext.TenantId) | Out-Null }
    foreach ($sp in ConvertTo-MaesterStringArray -Value (Get-MaesterPropertyValue -Object $test -Candidates @('ServicePrincipalIds', 'ServicePrincipals', 'AppIds', 'ApplicationIds'))) {
        if ($sp -match '^[0-9a-fA-F-]{36}$' -or $sp -match '^(?i)(appid|objectid):[0-9a-fA-F-]{36}$') {
            $entityRefs.Add($sp) | Out-Null
        }
    }
    $scopeObject = Get-MaesterPropertyValue -Object $test -Candidates @('Scope', 'Context')
    if ($scopeObject) {
        foreach ($sp in ConvertTo-MaesterStringArray -Value (Get-MaesterPropertyValue -Object $scopeObject -Candidates @('ServicePrincipalIds', 'ServicePrincipals', 'AppIds', 'ApplicationIds'))) {
            if ($sp -match '^[0-9a-fA-F-]{36}$' -or $sp -match '^(?i)(appid|objectid):[0-9a-fA-F-]{36}$') {
                $entityRefs.Add($sp) | Out-Null
            }
        }
    }
    foreach ($tag in $tags) {
        if ($tag -match '^(?i)spn:(?<id>[0-9a-fA-F-]{36})$') {
            $entityRefs.Add($Matches['id']) | Out-Null
        }
    }
    $entityRefsOut = @($entityRefs | Select-Object -Unique)

    $findings.Add([PSCustomObject]@{
        Id                  = "maester/$testId"
        TestId              = $testId
        Category            = $category
        Title               = if ((Get-MaesterPropertyValue -Object $test -Candidates @('Name'))) { [string](Get-MaesterPropertyValue -Object $test -Candidates @('Name')) } else { 'Unknown' }
        Severity            = $severity
        Compliant           = $compliant
        Detail              = $detail
        Remediation         = $remediation
        ResourceId          = ''
        LearnMoreUrl        = $learnMore
        Frameworks          = @($tagMetadata.Frameworks)
        Pillar              = 'Security'
        BaselineTags        = @($tagMetadata.BaselineTags)
        DeepLinkUrl         = $deepLinkUrl
        EvidenceUris        = @($evidenceUrisOut)
        RemediationSnippets = @(Get-MaesterRemediationSnippets -Text $remediation)
        EntityRefs          = @($entityRefsOut)
        ToolVersion         = $toolVersion
        MitreTactics        = @($tagMetadata.MitreTactics)
        MitreTechniques     = @($tagMetadata.MitreTechniques)
        SchemaVersion       = '1.0'
    })
}

return [PSCustomObject]@{
    SchemaVersion = '1.0'
    Source        = 'maester'
    Status        = 'Success'
    Message       = ''
    TenantId      = [string]$mgContext.TenantId
    ToolVersion   = $toolVersion
    Findings      = $findings
}
