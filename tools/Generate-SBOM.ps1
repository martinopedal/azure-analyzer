#Requires -Version 7.4
<#
.SYNOPSIS
    Generate CycloneDX 1.5 SBOM for azure-analyzer and all installed tools.

.DESCRIPTION
    Reads tools/install-manifest.json and emits a CycloneDX 1.5 JSON SBOM
    to output/sbom.json. Includes:
    - azure-analyzer itself as the top-level component
    - Each tool with version, SHA-256 (where available), download URL, license
    - Dependency relationships (azure-analyzer depends on each tool)

.PARAMETER OutputPath
    Path to write SBOM JSON. Defaults to output/sbom.json.

.PARAMETER ManifestPath
    Path to install manifest. Defaults to tools/install-manifest.json.

.EXAMPLE
    .\tools\Generate-SBOM.ps1
    Generates output/sbom.json from tools/install-manifest.json.

.EXAMPLE
    .\tools\Generate-SBOM.ps1 -OutputPath sbom-release.json
    Writes SBOM to custom path.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = 'output\sbom.json',
    [string]$ManifestPath = 'tools\install-manifest.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RepoMetadata {
    <#
    .SYNOPSIS
        Extract repo metadata from git (version, commit SHA, origin URL).
    #>
    $version = 'unknown'
    $commit = 'unknown'
    $url = 'https://github.com/martinopedal/azure-analyzer'
    
    try {
        # Try to get version from git tags
        $tagOutput = git describe --tags --exact-match 2>$null
        if ($LASTEXITCODE -eq 0 -and $tagOutput) {
            $version = $tagOutput -replace '^v', ''
        } else {
            # Fall back to branch + short SHA
            $branch = git rev-parse --abbrev-ref HEAD 2>$null
            $shortSha = git rev-parse --short HEAD 2>$null
            if ($LASTEXITCODE -eq 0 -and $shortSha) {
                $version = "${branch}-${shortSha}"
            }
        }
        
        # Get full commit SHA
        $commitSha = git rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $commitSha) {
            $commit = $commitSha
        }
        
        # Get remote origin URL
        $remoteUrl = git config --get remote.origin.url 2>$null
        if ($LASTEXITCODE -eq 0 -and $remoteUrl) {
            # Normalize git@ to https://
            $url = $remoteUrl -replace '^git@github\.com:', 'https://github.com/' -replace '\.git$', ''
        }
    } catch {
        Write-Warning "Could not extract git metadata: $($_.Exception.Message)"
    }
    
    return @{
        Version = $version
        Commit  = $commit
        Url     = $url
    }
}

function New-BomRef {
    <#
    .SYNOPSIS
        Generate a stable bom-ref (component identifier) for CycloneDX.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Version = 'unknown'
    )
    return "pkg:generic/$($Name.ToLowerInvariant())@$Version"
}

function ConvertTo-CycloneDXComponent {
    <#
    .SYNOPSIS
        Convert a tool entry from install-manifest.json to a CycloneDX component.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Tool,
        [string]$Type = 'application'
    )
    
    $component = [ordered]@{
        type    = $Type
        name    = $Tool.name
        version = $Tool.version
        'bom-ref' = New-BomRef -Name $Tool.name -Version $Tool.version
    }
    
    # Add upstream repository as external reference
    if ($Tool.PSObject.Properties['upstream'] -and $Tool.upstream) {
        $component.externalReferences = @(
            @{
                type = 'vcs'
                url  = $Tool.upstream
            }
        )
    }
    
    # Add SHA-256 hashes where available
    $hashes = @()
    if ($Tool.PSObject.Properties['platforms'] -and $Tool.platforms) {
        foreach ($platform in $Tool.platforms.PSObject.Properties) {
            $platformData = $platform.Value
            # Check if sha256 property exists and has a real value
            if ($platformData.PSObject.Properties['sha256'] -and 
                $platformData.sha256 -and 
                $platformData.sha256 -notlike '*PLACEHOLDER*') {
                $hashes += @{
                    alg     = 'SHA-256'
                    content = $platformData.sha256.ToLowerInvariant()
                }
                # Only add one hash entry to avoid duplication
                break
            }
        }
    }
    if ($hashes.Count -gt 0) {
        $component.hashes = $hashes
    }
    
    # Add properties for additional metadata
    $properties = @()
    
    if ($Tool.PSObject.Properties['pinType'] -and $Tool.pinType) {
        $properties += @{
            name  = 'pinType'
            value = $Tool.pinType
        }
    }
    
    # Add pinning notes from first platform with note
    if ($Tool.PSObject.Properties['platforms'] -and $Tool.platforms) {
        foreach ($platform in $Tool.platforms.PSObject.Properties) {
            $platformData = $platform.Value
            if ($platformData.PSObject.Properties['pinningNote'] -and $platformData.pinningNote) {
                $properties += @{
                    name  = 'pinningNote'
                    value = $platformData.pinningNote
                }
                break
            }
        }
    }
    
    if ($properties.Count -gt 0) {
        $component.properties = $properties
    }
    
    return $component
}

# Main execution
Write-Host "[sbom] Generating CycloneDX 1.5 SBOM..." -ForegroundColor Yellow

# Resolve paths
$repoRoot = Split-Path $PSScriptRoot -Parent
$manifestFullPath = Join-Path $repoRoot $ManifestPath
$outputFullPath = if ([System.IO.Path]::IsPathRooted($OutputPath)) { 
    $OutputPath 
} else { 
    Join-Path $repoRoot $OutputPath 
}

if (-not (Test-Path $manifestFullPath)) {
    Write-Error "Install manifest not found: $manifestFullPath"
    exit 1
}

# Read install manifest
Write-Verbose "Reading manifest from $manifestFullPath"
$manifest = Get-Content $manifestFullPath -Raw | ConvertFrom-Json

# Get repo metadata
$repoMeta = Get-RepoMetadata
Write-Verbose "Repo version: $($repoMeta.Version), commit: $($repoMeta.Commit)"

# Build CycloneDX SBOM structure
$sbom = [ordered]@{
    bomFormat   = 'CycloneDX'
    specVersion = '1.5'
    serialNumber = "urn:uuid:$([guid]::NewGuid().ToString())"
    version     = 1
    metadata    = @{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        component = @{
            type    = 'application'
            name    = 'azure-analyzer'
            version = $repoMeta.Version
            'bom-ref' = New-BomRef -Name 'azure-analyzer' -Version $repoMeta.Version
            externalReferences = @(
                @{
                    type = 'vcs'
                    url  = $repoMeta.Url
                },
                @{
                    type = 'website'
                    url  = 'https://github.com/martinopedal/azure-analyzer'
                }
            )
            properties = @(
                @{
                    name  = 'commit'
                    value = $repoMeta.Commit
                }
            )
        }
        tools = @(
            @{
                vendor  = 'martinopedal'
                name    = 'Generate-SBOM.ps1'
                version = '1.0.0'
            }
        )
    }
    components  = @()
    dependencies = @()
}

# Add each tool as a component
$toolDeps = @()
foreach ($tool in $manifest.tools) {
    Write-Verbose "Adding component: $($tool.name) v$($tool.version)"
    $component = ConvertTo-CycloneDXComponent -Tool $tool
    $sbom.components += $component
    $toolDeps += $component.'bom-ref'
}

# Add dependency relationships (azure-analyzer depends on all tools)
$sbom.dependencies = @(
    @{
        ref       = $sbom.metadata.component.'bom-ref'
        dependsOn = $toolDeps
    }
)

# Ensure output directory exists
$outputDir = Split-Path $outputFullPath -Parent
if (-not (Test-Path $outputDir)) {
    Write-Verbose "Creating output directory: $outputDir"
    $null = New-Item -ItemType Directory -Path $outputDir -Force
}

# Write SBOM
Write-Verbose "Writing SBOM to $outputFullPath"
$sbom | ConvertTo-Json -Depth 20 | Set-Content $outputFullPath -Encoding utf8

Write-Host "[sbom] Generated SBOM with $($sbom.components.Count) components: $outputFullPath" -ForegroundColor Green

# Output summary
$withHashes = $sbom.components | Where-Object { $_.PSObject.Properties['hashes'] -and $_.hashes }
$pinnedCount = if ($withHashes) { @($withHashes).Count } else { 0 }
$placeholderCount = $sbom.components.Count - $pinnedCount
Write-Host "       Pinned with SHA-256: $pinnedCount" -ForegroundColor Green
if ($placeholderCount -gt 0) {
    Write-Host "       Delegated to package manager: $placeholderCount (winget/brew/pipx/PSGallery)" -ForegroundColor Yellow
}
