#Requires -Version 7.4
[CmdletBinding()]
param ()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:FrameworkCatalogCache = @{}

function Get-ObjectPropertyValue {
    param (
        [Parameter(Mandatory)]
        [object] $Object,
        [Parameter(Mandatory)]
        [string] $PropertyName,
        $Default = $null
    )

    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$PropertyName]
    if ($null -eq $prop -or $null -eq $prop.Value) { return $Default }
    return $prop.Value
}

function Set-ObjectPropertyValue {
    param (
        [Parameter(Mandatory)]
        [object] $Object,
        [Parameter(Mandatory)]
        [string] $PropertyName,
        $Value
    )

    if ($null -eq $Object.PSObject.Properties[$PropertyName]) {
        $Object | Add-Member -NotePropertyName $PropertyName -NotePropertyValue $Value -Force
    } else {
        $Object.$PropertyName = $Value
    }
}

function Normalize-KeyPart {
    param ([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return $Value.Trim().ToLowerInvariant()
}

function ConvertTo-RuleSlug {
    param ([string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $slug = $Text.ToLowerInvariant() -replace '[^a-z0-9]+', '-' -replace '^-+', '' -replace '-+$', ''
    return $slug
}

function Test-IsGuidLike {
    param ([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $guidOut = [Guid]::Empty
    return [Guid]::TryParse($Value, [ref]$guidOut)
}

function Get-FrameworkMappingCatalog {
    [CmdletBinding()]
    param (
        [string] $MappingPath = (Join-Path $PSScriptRoot '..' '..' 'tools' 'framework-mappings.json')
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($MappingPath)
    if ($script:FrameworkCatalogCache.ContainsKey($resolvedPath)) {
        return $script:FrameworkCatalogCache[$resolvedPath]
    }

    if (-not (Test-Path $resolvedPath)) {
        $empty = [PSCustomObject]@{
            MappingPath = $resolvedPath
            Frameworks  = @()
            Mappings    = @{}
            ControlsByFramework = @{}
        }
        $script:FrameworkCatalogCache[$resolvedPath] = $empty
        return $empty
    }

    $raw = Get-Content -Path $resolvedPath -Raw | ConvertFrom-Json

    $frameworks = @($raw.frameworks)
    $mappingIndex = @{}
    $controlsByFramework = @{}

    foreach ($keyProp in $raw.mappings.PSObject.Properties) {
        $normalizedKey = Normalize-KeyPart $keyProp.Name
        $entries = @($keyProp.Value)
        $mappingIndex[$normalizedKey] = @($entries | ForEach-Object {
            [PSCustomObject]@{
                framework = [string]$_.framework
                control   = [string]$_.control
                citation  = [string]$_.citation
            }
        })

        foreach ($entry in $entries) {
            $fw = [string]$entry.framework
            $control = [string]$entry.control
            if ([string]::IsNullOrWhiteSpace($fw) -or [string]::IsNullOrWhiteSpace($control)) { continue }
            if (-not $controlsByFramework.ContainsKey($fw)) { $controlsByFramework[$fw] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase) }
            $null = $controlsByFramework[$fw].Add($control)
        }
    }

    $catalog = [PSCustomObject]@{
        MappingPath = $resolvedPath
        Frameworks  = $frameworks
        Mappings    = $mappingIndex
        ControlsByFramework = $controlsByFramework
    }
    $script:FrameworkCatalogCache[$resolvedPath] = $catalog
    return $catalog
}

function Get-FindingRuleId {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [pscustomobject] $Finding
    )

    foreach ($propertyName in @('RuleId', 'Rule', 'RuleName', 'CheckId', 'ControlId')) {
        $candidate = [string](Get-ObjectPropertyValue -Object $Finding -PropertyName $propertyName -Default '')
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return (Normalize-KeyPart $candidate)
        }
    }

    $source = Normalize-KeyPart ([string](Get-ObjectPropertyValue -Object $Finding -PropertyName 'Source' -Default ''))
    $category = [string](Get-ObjectPropertyValue -Object $Finding -PropertyName 'Category' -Default '')
    if ($source -eq 'psrule' -and -not [string]::IsNullOrWhiteSpace($category)) {
        return (Normalize-KeyPart $category)
    }

    $title = [string](Get-ObjectPropertyValue -Object $Finding -PropertyName 'Title' -Default '')
    $slug = ConvertTo-RuleSlug $title
    if (-not [string]::IsNullOrWhiteSpace($slug)) {
        return $slug
    }

    $idValue = [string](Get-ObjectPropertyValue -Object $Finding -PropertyName 'Id' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($idValue) -and -not (Test-IsGuidLike $idValue)) {
        return (Normalize-KeyPart $idValue)
    }

    return 'unknown'
}

function Get-FrameworkMappingsForFinding {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [pscustomobject] $Finding,
        [string] $MappingPath = (Join-Path $PSScriptRoot '..' '..' 'tools' 'framework-mappings.json')
    )

    $catalog = Get-FrameworkMappingCatalog -MappingPath $MappingPath
    $source = Normalize-KeyPart ([string](Get-ObjectPropertyValue -Object $Finding -PropertyName 'Source' -Default ''))
    $category = Normalize-KeyPart ([string](Get-ObjectPropertyValue -Object $Finding -PropertyName 'Category' -Default 'general'))
    if ([string]::IsNullOrWhiteSpace($category)) { $category = 'general' }
    $ruleId = Get-FindingRuleId -Finding $Finding

    $lookupKeys = @(
        "$source|$category|$ruleId",
        "$source|general|$ruleId"
    )

    foreach ($lookup in $lookupKeys) {
        $normalizedLookup = Normalize-KeyPart $lookup
        if ($catalog.Mappings.ContainsKey($normalizedLookup)) {
            return @($catalog.Mappings[$normalizedLookup])
        }
    }

    return @()
}

function Add-FrameworkMetadataToFinding {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [pscustomobject] $Finding,
        [string] $MappingPath = (Join-Path $PSScriptRoot '..' '..' 'tools' 'framework-mappings.json')
    )

    $mappings = @(Get-FrameworkMappingsForFinding -Finding $Finding -MappingPath $MappingPath)
    if ($mappings.Count -eq 0) {
        Set-ObjectPropertyValue -Object $Finding -PropertyName 'Frameworks' -Value @()
        Set-ObjectPropertyValue -Object $Finding -PropertyName 'Controls' -Value @()
        return $Finding
    }

    $frameworkObjects = [System.Collections.Generic.List[object]]::new()
    $controlSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($mapping in $mappings) {
        $framework = [string]$mapping.framework
        $control = [string]$mapping.control
        $citation = [string]$mapping.citation
        if ([string]::IsNullOrWhiteSpace($framework) -or [string]::IsNullOrWhiteSpace($control)) { continue }

        $frameworkObjects.Add([PSCustomObject]@{
            framework = $framework
            control   = $control
            citation  = $citation
        })

        $null = $controlSet.Add("$framework`: $control")
    }

    Set-ObjectPropertyValue -Object $Finding -PropertyName 'Frameworks' -Value @($frameworkObjects)
    Set-ObjectPropertyValue -Object $Finding -PropertyName 'Controls' -Value @($controlSet)
    return $Finding
}

function Add-FrameworkMetadata {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object[]] $Findings,
        [string] $MappingPath = (Join-Path $PSScriptRoot '..' '..' 'tools' 'framework-mappings.json')
    )

    $enriched = [System.Collections.Generic.List[object]]::new()
    foreach ($finding in @($Findings)) {
        if ($null -eq $finding) { continue }
        $enriched.Add((Add-FrameworkMetadataToFinding -Finding $finding -MappingPath $MappingPath))
    }

    return @($enriched)
}

function Select-FindingsByFramework {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object[]] $Findings,
        [Parameter(Mandatory)]
        [ValidateSet('CIS', 'NIST', 'PCI')]
        [string] $Framework
    )

    $selected = [System.Collections.Generic.List[object]]::new()
    foreach ($finding in @($Findings)) {
        if ($null -eq $finding) { continue }

        $frameworks = @($finding.Frameworks | Where-Object { $_.framework -eq $Framework })
        if ($frameworks.Count -eq 0) { continue }

        Set-ObjectPropertyValue -Object $finding -PropertyName 'Frameworks' -Value @($frameworks)
        Set-ObjectPropertyValue -Object $finding -PropertyName 'Controls' -Value @($frameworks | ForEach-Object { "$($_.framework): $($_.control)" } | Sort-Object -Unique)
        $selected.Add($finding)
    }

    return @($selected)
}

function Get-FrameworkCoverage {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object[]] $Findings,
        [string] $MappingPath = (Join-Path $PSScriptRoot '..' '..' 'tools' 'framework-mappings.json')
    )

    $catalog = Get-FrameworkMappingCatalog -MappingPath $MappingPath
    $coverage = [System.Collections.Generic.List[object]]::new()

    foreach ($frameworkDef in @($catalog.Frameworks)) {
        $frameworkName = [string]$frameworkDef.name
        if ([string]::IsNullOrWhiteSpace($frameworkName)) { continue }

        $displayName = [string]$frameworkDef.displayName
        if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $frameworkName }

        $totalControls = 0
        if ($catalog.ControlsByFramework.ContainsKey($frameworkName)) {
            $totalControls = $catalog.ControlsByFramework[$frameworkName].Count
        }

        $coveredSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($finding in @($Findings)) {
            foreach ($entry in @($finding.Frameworks)) {
                if ($null -eq $entry) { continue }
                if ([string]$entry.framework -ne $frameworkName) { continue }
                $control = [string]$entry.control
                if ([string]::IsNullOrWhiteSpace($control)) { continue }
                $null = $coveredSet.Add($control)
            }
        }

        $coveredControls = $coveredSet.Count
        $percent = if ($totalControls -gt 0) { [math]::Round(($coveredControls / $totalControls) * 100) } else { 0 }
        $status = if ($percent -ge 80) { 'green' } elseif ($percent -ge 40) { 'yellow' } else { 'red' }

        $coverage.Add([PSCustomObject]@{
            Framework      = $frameworkName
            DisplayName    = $displayName
            CoveredControls = $coveredControls
            TotalControls  = $totalControls
            Percent        = $percent
            Status         = $status
        })
    }

    return @($coverage)
}
