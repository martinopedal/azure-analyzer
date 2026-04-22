#Requires -Version 7.4
<#
Tests for scripts/Resolve-CommonMergeConflicts.ps1 -- auto-resolution helper used
by the pr-auto-rebase workflow. Covers happy-path union merge, dedupe semantics,
JSON validation aborting on genuine conflicts, and malformed-input rejection.
#>

BeforeAll {
    $script:RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:ScriptPath = Join-Path $script:RepoRoot 'scripts' 'Resolve-CommonMergeConflicts.ps1'
    $script:FixturesDir = Join-Path $script:RepoRoot 'tests' 'fixtures' 'merge-conflicts'

    function Copy-Fixture {
        param([string] $Name)
        $src = Join-Path $script:FixturesDir $Name
        $dst = Join-Path ([System.IO.Path]::GetTempPath()) ("rcmc-" + [guid]::NewGuid().ToString('N') + "-$Name")
        Copy-Item -LiteralPath $src -Destination $dst -Force
        return $dst
    }
}

Describe 'Resolve-CommonMergeConflicts.ps1' {
    It 'exists and parses' {
        Test-Path $script:ScriptPath | Should -BeTrue
        { [scriptblock]::Create((Get-Content -Raw $script:ScriptPath)) } | Should -Not -Throw
    }

    Context 'Changelog strategy' {
        It 'merges both sides additively' {
            $tmp = Copy-Fixture 'changelog-additive.md'
            try {
                $result = & $script:ScriptPath -Path $tmp -Strategy Changelog
                $result.Resolved   | Should -BeTrue
                $result.BlockCount | Should -Be 1
                $content = Get-Content -Raw $tmp
                $content | Should -Not -Match '<<<<<<<'
                $content | Should -Not -Match '======='
                $content | Should -Not -Match '>>>>>>>'
                $content | Should -Match 'auto-rebase agent PRs'
                $content | Should -Match 'retry wrap for flaky network steps'
                $content | Should -Match 'cookie-bootstrap auth'
                $content | Should -Match 'fix\(orchestrator\)'
            } finally {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        }

        It 'dedupes identical entries appearing on both sides' {
            $tmp = Copy-Fixture 'changelog-additive.md'
            try {
                & $script:ScriptPath -Path $tmp -Strategy Changelog | Out-Null
                $occurrences = ([regex]::Matches((Get-Content -Raw $tmp), 'auto-rebase agent PRs')).Count
                $occurrences | Should -Be 1
            } finally {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Manifest strategy' {
        It 'merges additive JSON entries and stays valid JSON' {
            $tmp = Copy-Fixture 'manifest-additive.json'
            try {
                $result = & $script:ScriptPath -Path $tmp -Strategy Manifest
                $result.Resolved | Should -BeTrue
                $content = Get-Content -Raw $tmp
                $content | Should -Not -Match '<<<<<<<'
                { $content | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw
                $parsed = $content | ConvertFrom-Json
                $names = $parsed.tools.name
                $names | Should -Contain 'attack-path'
                $names | Should -Contain 'resilience-map'
                $names | Should -Contain 'policy-viz'
                ($names | Where-Object { $_ -eq 'policy-viz' }).Count | Should -Be 1
            } finally {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        }

        It 'aborts (throws) when union merge produces invalid JSON (genuine conflict)' {
            $tmp = Copy-Fixture 'manifest-genuine-conflict.json'
            try {
                { & $script:ScriptPath -Path $tmp -Strategy Manifest } | Should -Throw -ExpectedMessage '*validation*'
            } finally {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'DocAddition strategy' {
        It 'merges README feature lists additively' {
            $tmp = Copy-Fixture 'readme-additive.md'
            try {
                $result = & $script:ScriptPath -Path $tmp -Strategy DocAddition
                $result.Resolved | Should -BeTrue
                $content = Get-Content -Raw $tmp
                $content | Should -Not -Match '<<<<<<<'
                $content | Should -Match '4-tier viewer scaffold'
                $content | Should -Match 'Retry wrapper for flaky steps'
                $content | Should -Match 'Auto-rebase for agent PRs'
                ([regex]::Matches($content, 'Auto-rebase for agent PRs')).Count | Should -Be 1
            } finally {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Error handling' {
        It 'throws on a missing file' {
            { & $script:ScriptPath -Path 'C:\does\not\exist.md' -Strategy Changelog } |
                Should -Throw -ExpectedMessage '*not found*'
        }

        It 'throws when no conflict markers are present' {
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("rcmc-clean-" + [guid]::NewGuid().ToString('N') + ".md")
            Set-Content -LiteralPath $tmp -Value "# clean`n- no conflicts here`n"
            try {
                { & $script:ScriptPath -Path $tmp -Strategy Changelog } |
                    Should -Throw -ExpectedMessage '*No conflict markers*'
            } finally {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        }

        It 'throws on a malformed conflict block (missing >>>>>>>)' {
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("rcmc-malformed-" + [guid]::NewGuid().ToString('N') + ".md")
            Set-Content -LiteralPath $tmp -Value "head`n<<<<<<< HEAD`nours`n=======`ntheirs`n"
            try {
                { & $script:ScriptPath -Path $tmp -Strategy Changelog } |
                    Should -Throw -ExpectedMessage '*Malformed conflict block*'
            } finally {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        }

        It 'rejects unknown strategy values via parameter validation' {
            { & $script:ScriptPath -Path $script:ScriptPath -Strategy 'Bogus' } |
                Should -Throw
        }
    }
}
