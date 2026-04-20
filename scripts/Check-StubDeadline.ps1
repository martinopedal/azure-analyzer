#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Check', 'Remove', 'Report')]
    [string]$Mode = 'Check',
    [string]$RepoRoot,
    [string]$RegistryPath,
    [string]$ModuleManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RepoRoot {
    $candidate = Split-Path -Parent $PSScriptRoot
    if (-not $candidate) {
        $candidate = (Get-Location).Path
    }
    return $candidate
}

function Resolve-DefaultPath {
    param(
        [string]$BasePath,
        [string]$RelativePath,
        [string]$ProvidedPath
    )

    if ($ProvidedPath) {
        return $ProvidedPath
    }

    return Join-Path $BasePath $RelativePath
}

$defaultRepoRoot = Get-RepoRoot
$basePath = if ($RepoRoot) { $RepoRoot } else { $defaultRepoRoot }
$RegistryPath = Resolve-DefaultPath -BasePath $basePath -RelativePath '.squad\stub-deadlines.json' -ProvidedPath $RegistryPath
$ModuleManifestPath = Resolve-DefaultPath -BasePath $basePath -RelativePath 'AzureAnalyzer.psd1' -ProvidedPath $ModuleManifestPath

if (-not (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) {
    throw "Stub deadline registry not found at: $RegistryPath"
}

if (-not (Test-Path -LiteralPath $ModuleManifestPath -PathType Leaf)) {
    throw "Module manifest not found at: $ModuleManifestPath"
}

$resolvedManifestPath = (Resolve-Path -LiteralPath $ModuleManifestPath).Path
if ($RepoRoot) {
    $repoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
} elseif ($PSBoundParameters.ContainsKey('ModuleManifestPath')) {
    $repoRoot = Split-Path -Parent $resolvedManifestPath
} else {
    $repoRoot = $defaultRepoRoot
}

$moduleManifest = Import-PowerShellDataFile -LiteralPath $resolvedManifestPath
if (-not $moduleManifest.ModuleVersion) {
    throw "ModuleVersion missing from module manifest: $ModuleManifestPath"
}

[Version]$currentVersion = $moduleManifest.ModuleVersion
$registry = Get-Content -LiteralPath $RegistryPath -Raw | ConvertFrom-Json
$stubs = @($registry.stubs)

if ($stubs.Count -eq 0) {
    throw "No stubs declared in registry: $RegistryPath"
}

$results = foreach ($stub in $stubs) {
    if (-not $stub.path) {
        throw "Registry entry missing 'path': $($stub | ConvertTo-Json -Compress)"
    }
    if (-not $stub.expiresAt) {
        throw "Registry entry missing 'expiresAt' for path: $($stub.path)"
    }

    [Version]$expiresAt = $stub.expiresAt
    $stubPath = Join-Path $repoRoot $stub.path
    $exists = Test-Path -LiteralPath $stubPath -PathType Leaf
    $isExpired = $currentVersion -ge $expiresAt

    [PSCustomObject]@{
        Path            = $stub.path
        ReplacementPath = $stub.replacementPath
        ExpiresAt       = $expiresAt.ToString()
        CurrentVersion  = $currentVersion.ToString()
        Exists          = $exists
        IsExpired       = $isExpired
    }
}

$expiredPresent = @($results | Where-Object { $_.Exists -and $_.IsExpired })

switch ($Mode) {
    'Report' {
        $results |
            Sort-Object Path |
            Select-Object Path, ReplacementPath, ExpiresAt, CurrentVersion, Exists, IsExpired
        exit 0
    }

    'Check' {
        if ($expiredPresent.Count -gt 0) {
            Write-Host "Expired stub files detected for module version ${currentVersion}:"
            foreach ($item in $expiredPresent | Sort-Object Path) {
                Write-Host " - $($item.Path) -> $($item.ReplacementPath) (expired at $($item.ExpiresAt))"
            }
            exit 1
        }

        Write-Host "Stub deadline check passed for module version $currentVersion."
        Write-Host "Tracked stubs: $($results.Count). Expired stubs present: 0."
        exit 0
    }

    'Remove' {
        foreach ($item in $expiredPresent) {
            $absolutePath = Join-Path $repoRoot $item.Path
            Remove-Item -LiteralPath $absolutePath -Force
            Write-Host "Removed expired stub: $($item.Path)"
        }

        Write-Host "Stub removal complete for module version $currentVersion."
        Write-Host "Removed stubs: $($expiredPresent.Count)."
        exit 0
    }
}
