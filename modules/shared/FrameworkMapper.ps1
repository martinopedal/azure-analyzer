#requires -Version 7.0
<#
.SYNOPSIS
    FrameworkMapper: enriches v2 FindingRow objects with CIS/NIST/PCI control mappings.

.DESCRIPTION
    Loads tools/framework-mappings.json once and matches each finding by Source + Category
    (or RuleIdPrefix). Populates the finding's Frameworks[] and Controls[] fields.

    The mapping file is user-extensible — entries added by users merge with the defaults
    without modifying code.
#>

$script:__FrameworkMap = $null

function Get-FrameworkMappings {
    [CmdletBinding()]
    param([string]$Path)

    if ($script:__FrameworkMap -and -not $Path) { return $script:__FrameworkMap }

    if (-not $Path) {
        $Path = Join-Path (Split-Path $PSScriptRoot -Parent) '..' 'tools' 'framework-mappings.json'
    }
    if (-not (Test-Path $Path)) {
        Write-Warning "framework-mappings.json not found at $Path"
        return $null
    }

    try {
        $json = Get-Content $Path -Raw | ConvertFrom-Json -Depth 20
    } catch {
        Write-Warning "Failed to parse framework-mappings.json: $_"
        return $null
    }

    $script:__FrameworkMap = $json
    return $json
}

function Clear-FrameworkMappingCache {
    $script:__FrameworkMap = $null
}

function Test-MappingMatch {
    param(
        [Parameter(Mandatory)] $Finding,
        [Parameter(Mandatory)] $Match
    )
    foreach ($key in $Match.PSObject.Properties.Name) {
        $want = $Match.$key
        switch ($key) {
            'Category'      { if ($Finding.Category -ne $want) { return $false } }
            'RuleIdPrefix'  { if (-not $Finding.RuleId -or -not $Finding.RuleId.ToString().StartsWith($want)) { return $false } }
            'Check'         { if ($Finding.Check -ne $want) { return $false } }
            default         { return $false }
        }
    }
    return $true
}

function Add-FrameworkMapping {
    <#
    .SYNOPSIS
        Populates Frameworks[] and Controls[] on a v2 FindingRow based on source + category.
    .PARAMETER Finding
        A v2 FindingRow (PSCustomObject) — mutated in place.
    .PARAMETER FilterFramework
        Optional — if set (CIS/NIST/PCI), only controls for that framework are written.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] $Finding,
        [string]$FilterFramework,
        [object]$MappingData
    )
    process {
        if (-not $Finding) { return }
        $mappings = if ($MappingData) { $MappingData } else { Get-FrameworkMappings }
        if (-not $mappings) { return $Finding }

        $frameworks = [System.Collections.Generic.List[object]]::new()
        $controls   = [System.Collections.Generic.List[string]]::new()

        foreach ($rule in $mappings.mappings) {
            if ($rule.source -ne $Finding.Source) { continue }
            if (-not (Test-MappingMatch -Finding $Finding -Match $rule.match)) { continue }

            foreach ($fw in $rule.controls.PSObject.Properties) {
                if ($FilterFramework -and $fw.Name -ne $FilterFramework) { continue }
                foreach ($ctl in $fw.Value) {
                    $label = "$($fw.Name):$ctl"
                    if ($controls -notcontains $label) {
                        $controls.Add($label) | Out-Null
                    }
                    $existing = $frameworks | Where-Object { $_.framework -eq $fw.Name }
                    if (-not $existing) {
                        $frameworks.Add([pscustomobject]@{ framework = $fw.Name; controls = @($ctl) }) | Out-Null
                    } else {
                        if ($existing.controls -notcontains $ctl) {
                            $existing.controls = @($existing.controls) + $ctl
                        }
                    }
                }
            }
        }

        if ($frameworks.Count -gt 0) {
            # Write back — mutate the object if it exposes Frameworks/Controls properties.
            if ($Finding.PSObject.Properties.Name -contains 'Frameworks') {
                $Finding.Frameworks = @($frameworks)
            } else {
                $Finding | Add-Member -NotePropertyName Frameworks -NotePropertyValue @($frameworks) -Force
            }
            if ($Finding.PSObject.Properties.Name -contains 'Controls') {
                $Finding.Controls = @($controls)
            } else {
                $Finding | Add-Member -NotePropertyName Controls -NotePropertyValue @($controls) -Force
            }
        }
        return $Finding
    }
}

function Get-FrameworkCoverage {
    <#
    .SYNOPSIS
        Summarizes per-framework control coverage across a set of findings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Findings,
        [object]$MappingData
    )
    $mappings = if ($MappingData) { $MappingData } else { Get-FrameworkMappings }
    if (-not $mappings) { return @() }

    # Build the "universe" of controls referenced anywhere in the map (what COULD be touched).
    $universe = @{}
    foreach ($rule in $mappings.mappings) {
        foreach ($fw in $rule.controls.PSObject.Properties) {
            if (-not $universe.ContainsKey($fw.Name)) { $universe[$fw.Name] = @{} }
            foreach ($ctl in $fw.Value) { $universe[$fw.Name][$ctl] = $true }
        }
    }

    # Count controls actually touched by current findings.
    $touched = @{}
    foreach ($f in $Findings) {
        if (-not $f.Frameworks) { continue }
        foreach ($block in $f.Frameworks) {
            if (-not $touched.ContainsKey($block.framework)) { $touched[$block.framework] = @{} }
            foreach ($ctl in $block.controls) { $touched[$block.framework][$ctl] = $true }
        }
    }

    $out = @()
    foreach ($fwName in $universe.Keys | Sort-Object) {
        $total = $universe[$fwName].Count
        $hit   = if ($touched.ContainsKey($fwName)) { $touched[$fwName].Count } else { 0 }
        $pct   = if ($total -gt 0) { [math]::Round(($hit / $total) * 100, 1) } else { 0 }
        $status = if ($pct -ge 70) { 'green' } elseif ($pct -ge 30) { 'yellow' } else { 'red' }
        $meta = $mappings.frameworks.$fwName
        $out += [pscustomobject]@{
            Framework     = $fwName
            DisplayName   = if ($meta) { $meta.name } else { $fwName }
            Version       = if ($meta) { $meta.version } else { '' }
            ControlsTotal = $total
            ControlsHit   = $hit
            PercentCovered = $pct
            Status        = $status
        }
    }
    return $out
}
