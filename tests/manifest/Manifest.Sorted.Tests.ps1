#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

Describe 'tool-manifest ordering' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:ManifestPath = Join-Path $script:RepoRoot 'tools\tool-manifest.json'
        $script:Manifest = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
    }

    It 'orders tools alphabetically by name (case-insensitive)' {
        $names = @($script:Manifest.tools | ForEach-Object { $_.name })
        $sorted = @($names | Sort-Object { $_.ToLowerInvariant() })

        ($names -join ',') | Should -Be ($sorted -join ',')
    }
}
