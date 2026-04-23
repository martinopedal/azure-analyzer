#Requires -Version 7.4

Describe 'E2E wrapper coverage parity tracker' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:Manifest = Get-Content (Join-Path $script:RepoRoot 'tools' 'tool-manifest.json') -Raw | ConvertFrom-Json
        $script:Tracker  = Get-Content (Join-Path $script:RepoRoot 'docs' 'audits' 'e2e-wrapper-coverage-parity.json') -Raw | ConvertFrom-Json

        $script:EnabledTools = @($script:Manifest.tools | Where-Object { $_.enabled } | ForEach-Object { $_.name })
        $script:TrackedTools = @($script:Tracker.entries | ForEach-Object { $_.tool })
    }

    It 'tracks every enabled tool in tool-manifest.json' {
        @($script:TrackedTools).Count | Should -Be @($script:EnabledTools).Count

        $missing = @($script:EnabledTools | Where-Object { $_ -notin $script:TrackedTools })
        $extra   = @($script:TrackedTools | Where-Object { $_ -notin $script:EnabledTools })

        @($missing).Count | Should -Be 0
        @($extra).Count   | Should -Be 0
    }

    It 'uses contiguous E2E IDs aligned to entry count' {
        $expected = 1..@($script:Tracker.entries).Count | ForEach-Object { 'E2E-{0:D3}' -f $_ }
        $actual   = @($script:Tracker.entries | ForEach-Object { $_.id })
        $actual | Should -Be $expected
    }

    It 'has unique tool entries (one row per enabled tool)' {
        $names = @($script:Tracker.entries | ForEach-Object { $_.tool })
        $unique = $names | Sort-Object -Unique
        @($names).Count | Should -Be @($unique).Count
    }

    It 'has unique tool names in tool-manifest.json' {
        $names = @($script:Manifest.tools | ForEach-Object { $_.name })
        $unique = $names | Sort-Object -Unique
        @($names).Count | Should -Be @($unique).Count
    }

    It 'uses valid status values for each tracked tool' {
        $allowed = @('not-covered', 'in-progress', 'covered')
        foreach ($entry in @($script:Tracker.entries)) {
            $entry.status | Should -BeIn $allowed
        }
    }
}
