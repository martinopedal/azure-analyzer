#Requires -Version 7.0

Describe 'Release automation workflow contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:WorkflowPath = Join-Path $script:RepoRoot '.github' 'workflows' 'release.yml'
        $script:ConfigPath = Join-Path $script:RepoRoot 'release-please-config.json'
        $script:ManifestPath = Join-Path $script:RepoRoot '.release-please-manifest.json'
    }

    It 'defines release-please main branch phase and tag publish phase' {
        $workflow = Get-Content -Path $script:WorkflowPath -Raw

        $workflow | Should -Match '(?m)^\s*branches:\s*\[main\]'
        $workflow | Should -Match "(?m)^\s+- 'v\*\.\*\.\*'"
        $workflow | Should -Match 'googleapis/release-please-action@[0-9a-f]{40}'
        $workflow | Should -Match "if: github.event_name == 'push' && github.ref == 'refs/heads/main'"
        $workflow | Should -Match "if: startsWith\(github\.ref, 'refs/tags/v'\) \|\| github\.event_name == 'workflow_dispatch'"
    }

    It 'builds required release artifacts and PSGallery publish checks' {
        $workflow = Get-Content -Path $script:WorkflowPath -Raw

        $workflow | Should -Match 'AzureAnalyzer-\$tag\.zip'
        $workflow | Should -Match 'output/sbom\.json'
        $workflow | Should -Match 'SHA256SUMS\.txt'
        $workflow | Should -Match 'Publish-Module.+-WhatIf'
        $workflow | Should -Match '\$null = Find-Module'
        $workflow | Should -Match 'Save-Module -Name \$moduleName'
    }

    It 'includes release-please manifest config and psd1 anchor' {
        $config = Get-Content -Path $script:ConfigPath -Raw | ConvertFrom-Json
        $manifest = Get-Content -Path $script:ManifestPath -Raw | ConvertFrom-Json
        $psd1 = Get-Content -Path (Join-Path $script:RepoRoot 'AzureAnalyzer.psd1') -Raw

        $config.'release-type' | Should -Be 'simple'
        $config.packages.PSObject.Properties.Name | Should -Contain '.' -Because "release-please manifest mode requires a root package entry named '.'"
        ($config.packages.'.'.'extra-files' | Where-Object { $_.path -eq 'AzureAnalyzer.psd1' }).Count | Should -BeGreaterThan 0
        $manifest.'.' | Should -Match '^\d+\.\d+\.\d+$'
        $psd1 | Should -Match "ModuleVersion\s*=\s*'\d+\.\d+\.\d+'\s*#\s*x-release-please-version"
    }

    It 'keeps release-please manifest version in sync with psd1 ModuleVersion' {
        $manifest = Get-Content -Path $script:ManifestPath -Raw | ConvertFrom-Json
        $psd1 = Get-Content -Path (Join-Path $script:RepoRoot 'AzureAnalyzer.psd1') -Raw

        $match = [regex]::Match($psd1, "ModuleVersion\s*=\s*'(?<version>\d+\.\d+\.\d+)'\s*#\s*x-release-please-version")
        $match.Success | Should -BeTrue
        $manifest.'.' | Should -Be $match.Groups['version'].Value
    }

    It 'keeps release automation files em-dash free' {
        foreach ($path in @($script:WorkflowPath, $script:ConfigPath, (Join-Path $script:RepoRoot 'docs' 'RELEASING.md'))) {
            $content = Get-Content -Path $path -Raw
            $content | Should -Not -Match '—'
        }
    }
}
