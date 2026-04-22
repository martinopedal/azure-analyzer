#Requires -Version 7.0
<#
.SYNOPSIS
    Ratchet test for CI transcript hygiene (#472, sweep #3 category 12).

.DESCRIPTION
    Runs the wrapper test suite in an isolated child pwsh process, captures
    stdout + stderr, and asserts that no "<tool> is not installed" style
    Write-Warning leaks into the transcript. The bootstrap file
    tests/_Bootstrap.Tests.ps1 sets AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS
    which routes Write-MissingToolNotice through Write-Verbose.

    The baseline is zero WARNING lines matching the tool-missing pattern.
    If this count rises, the PR MUST either:
      - route the new wrapper's tool-missing check through Write-MissingToolNotice
        (modules/shared/MissingTool.ps1), OR
      - mock Get-Command / Get-Module in the new test via
        tests/_helpers/Mock-ToolPresence.ps1.

    Grandfathered exceptions: none. Tighten this test, don't relax it.

    This test is gated behind the AZURE_ANALYZER_RUN_HYGIENE_GATE env var so
    it doesn't explode the main suite runtime. CI can set it on the nightly
    schedule; local developers opt in via:
      $env:AZURE_ANALYZER_RUN_HYGIENE_GATE = '1'
      Invoke-Pester -Path tests/ci
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'CI transcript hygiene (category 12 ratchet)' -Tag 'HygieneGate' {
    BeforeAll {
        $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
        $script:WrappersPath = Join-Path $script:RepoRoot 'tests' 'wrappers'
    }

    It 'emits zero "<tool> is not installed" WARNING lines during wrapper tests' -Skip:(-not ($env:AZURE_ANALYZER_RUN_HYGIENE_GATE -in @('1', 'true', 'yes', 'on'))) {
        $transcript = Join-Path $script:RepoRoot 'tests' 'ci' "hygiene-transcript-$([guid]::NewGuid().ToString('N')).log"
        $cmd = @"
Import-Module Pester -MinimumVersion 5.0 -Force
Set-Location '$($script:RepoRoot.Path.Replace("'", "''"))'
`$null = Invoke-Pester -Path '$($script:WrappersPath.Replace("'", "''"))' -PassThru -Output None
"@
        try {
            & pwsh -NoProfile -NonInteractive -Command $cmd *> $transcript
            $content = Get-Content -LiteralPath $transcript -Raw -ErrorAction SilentlyContinue
            $offenders = @()
            if ($content) {
                $offenders = $content -split "`n" | Where-Object {
                    $_ -match '^\s*WARNING:.*(not installed|not found|module not|CLI is|Skipping)'
                }
            }
            if ($offenders.Count -gt 0) {
                $sample = ($offenders | Select-Object -First 5) -join "`n"
                throw "Detected $($offenders.Count) tool-missing WARNING line(s) in wrapper-test transcript. First 5:`n$sample`n`nFix: route the wrapper's tool-presence check through Write-MissingToolNotice (modules/shared/MissingTool.ps1), or mock it in the test via tests/_helpers/Mock-ToolPresence.ps1."
            }
        }
        finally {
            if (Test-Path $transcript) { Remove-Item -LiteralPath $transcript -Force -ErrorAction SilentlyContinue }
        }
    }
}
