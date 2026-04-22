#Requires -Version 7.4

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    . (Join-Path $repoRoot 'modules\shared\Sanitize.ps1')
    . (Join-Path $repoRoot 'modules\shared\ReportVerification.ps1')
}

Describe 'ReportVerification per-tier stubs (#435)' {
    BeforeAll {
        $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("phase0-verify-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:tmpRoot -Force | Out-Null
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:tmpRoot) {
            Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'exposes the canonical 4-tier list' {
        $tiers = @((Get-ReportVerificationTiers) | ForEach-Object { $_ })
        $tiers.Count | Should -Be 4
        $tiers | Should -Contain 'PureJson'
        $tiers | Should -Contain 'EmbeddedSqlite'
        $tiers | Should -Contain 'SidecarSqlite'
        $tiers | Should -Contain 'PodeViewer'
    }

    Context 'Test-PureJsonOutput' {
        It 'returns success when at least one canonical artefact exists' {
            'placeholder' | Set-Content -LiteralPath (Join-Path $script:tmpRoot 'results.json')
            $r = Test-PureJsonOutput -ReportRoot $script:tmpRoot
            $r.Tier | Should -Be 'PureJson'
            $r.Success | Should -BeTrue
            $r.Status | Should -Be 'ready'
        }

        It 'returns missing-outputs when the directory is empty' {
            $emptyDir = Join-Path $script:tmpRoot 'empty'
            New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
            $r = Test-PureJsonOutput -ReportRoot $emptyDir
            $r.Success | Should -BeFalse
            $r.Status | Should -Be 'missing-outputs'
            $r.Errors.Count | Should -BeGreaterThan 0
        }

        It 'flags invalid arguments when the path is missing' {
            $r = Test-PureJsonOutput -ReportRoot (Join-Path $script:tmpRoot 'does-not-exist')
            $r.Success | Should -BeFalse
            $r.Status | Should -Be 'invalid-arguments'
        }
    }

    Context 'placeholder tiers' {
        It 'returns Status=placeholder for EmbeddedSqlite' {
            $r = Test-EmbeddedSqliteOutput -ReportRoot $script:tmpRoot
            $r.Success | Should -BeFalse
            $r.Status | Should -Be 'placeholder'
            $r.Warnings.Count | Should -BeGreaterThan 0
        }

        It 'returns Status=placeholder for SidecarSqlite' {
            $r = Test-SidecarSqliteOutput -ReportRoot $script:tmpRoot
            $r.Status | Should -Be 'placeholder'
        }

        It 'returns Status=placeholder for PodeViewer' {
            $r = Test-PodeViewerOutput -ReportRoot $script:tmpRoot
            $r.Status | Should -Be 'placeholder'
        }
    }

    Context 'Invoke-ReportVerification dispatch' {
        It 'routes to the correct per-tier verifier' {
            $r = Invoke-ReportVerification -Tier 'PureJson' -ReportRoot $script:tmpRoot
            $r.Tier | Should -Be 'PureJson'
        }

        It 'throws on unknown tier' {
            { Invoke-ReportVerification -Tier 'NotATier' -ReportRoot $script:tmpRoot } | Should -Throw
        }
    }

    Context 'sanitization parity' {
        It 'scrubs credentials from emitted error messages' {
            $r = New-ReportVerificationResult -Tier 'PureJson' -Success $false -Status 'invalid-arguments' `
                -Errors @('AccountKey=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==')
            ($r.Errors -join ' ') | Should -Not -Match 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
        }
    }
}
