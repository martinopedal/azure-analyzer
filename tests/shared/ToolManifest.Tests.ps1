#Requires -Version 7.4

Describe 'tool-manifest upstream metadata' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
        $manifestPath = Join-Path $repoRoot 'tools\tool-manifest.json'
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
        $toolsWithUpstream = @($manifest.tools | Where-Object { $null -ne $_.upstream })
    }

    It 'keeps upstream metadata on at least one tool' {
        $toolsWithUpstream.Count | Should -BeGreaterThan 0
    }

    It 'uses supported upstream pinType values' {
        foreach ($tool in $toolsWithUpstream) {
            $tool.upstream.pinType | Should -BeIn @('semver', 'sha', 'cli-version')
        }
    }

    It 'defines required upstream fields' {
        foreach ($tool in $toolsWithUpstream) {
            $tool.upstream.repo | Should -Match '^[^/]+/[^/]+$'
            $tool.upstream.releaseApi | Should -Match '^repos/[^/]+/[^/]+/releases/latest$'
            $tool.upstream.currentPin | Should -Not -BeNullOrEmpty
        }
    }
}
