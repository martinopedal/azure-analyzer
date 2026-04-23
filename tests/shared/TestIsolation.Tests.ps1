#Requires -Version 7.0
<#
.SYNOPSIS
    Guard test for #746: every test file that mutates $env: or $global: state
    MUST also restore that state in an AfterAll/AfterEach block, so that test
    order doesn't leak shared-process state across files (especially on macOS
    / Linux runners that share a single pwsh process).

.NOTES
    The guard is heuristic, not a full AST parse:
      * Files containing `$env:NAME = ...` writes must also contain either an
        `AfterAll` / `AfterEach` block, OR a `Remove-Item Env:NAME` call, OR
        an inline restore (`$env:NAME = $script:_orig*`).
      * Files containing `$global:NAME = ...` writes (excluding the auto-managed
        `$global:LASTEXITCODE`) must also contain `Remove-Variable -Scope Global`
        or `Set-Variable -Scope Global` for restoration.

    Add new exemptions to `$script:Exemptions` ONLY with a written justification.
#>

Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:TestsRoot = Join-Path $script:RepoRoot 'tests'

    # Files that legitimately do not need an AfterAll-style restore (e.g.
    # they only READ env vars, or the file is itself a guard test).
    $script:Exemptions = @(
        'tests/shared/TestIsolation.Tests.ps1'
    )

    $script:AllTestFiles = Get-ChildItem -Path $script:TestsRoot -Recurse -Filter '*.Tests.ps1' -File |
        ForEach-Object { $_.FullName }
}

Describe 'Test isolation guard (#746)' -Tag 'isolation' {

    It 'every test file that writes $env:* has lifecycle cleanup and env restore operations' {
        $offenders = [System.Collections.Generic.List[string]]::new()
        foreach ($file in $script:AllTestFiles) {
            $relative = ($file.Substring($script:RepoRoot.Length + 1)).Replace('\', '/')
            if ($script:Exemptions -contains $relative) { continue }

            $content = Get-Content -LiteralPath $file -Raw
            if ([string]::IsNullOrWhiteSpace($content)) { continue }

            # Strip block + line comments so doc-comment env examples don't
            # get flagged. Order matters: block first, then line.
            $code = [regex]::Replace($content, '<#.*?#>', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
            $code = ($code -split "`n" | ForEach-Object { ($_ -replace '#.*$', '') }) -join "`n"

            $writes = [regex]::Matches($code, '\$env:([A-Z][A-Z0-9_]*)\s*=')
            if ($writes.Count -eq 0) { continue }

            $hasAfterBlock =
                ($code -match '(?im)^\s*AfterAll\s*\{') -or
                ($code -match '(?im)^\s*AfterEach\s*\{')
            $hasFinallyRestore = $code -match '(?is)\bfinally\s*\{[^}]*?(Remove-Item\s+Env:|Remove-Item\s+Env:\\|\$env:[A-Z][A-Z0-9_]*\s*=\s*\$)'
            $hasRestoreOp =
                ($code -match '(?i)Remove-Item\s+Env:') -or
                ($code -match '(?i)Remove-Item\s+Env:\\') -or
                ($code -match '\$env:[A-Z][A-Z0-9_]*\s*=\s*\$(script:|global:|env:)?[A-Za-z_][A-Za-z0-9_]*')

            if (-not (($hasAfterBlock -or $hasFinallyRestore) -and $hasRestoreOp)) {
                $offenders.Add("$relative (missing cleanup lifecycle block and/or env restore operation)") | Out-Null
            }
        }

        $offenders -join "`n" | Should -BeNullOrEmpty -Because "every test file that mutates `$env:* must restore it; offenders:`n$($offenders -join "`n")"
    }

    It 'every test file that writes $global:* (other than LASTEXITCODE) has lifecycle cleanup and global restore operations' {
        $offenders = [System.Collections.Generic.List[string]]::new()
        foreach ($file in $script:AllTestFiles) {
            $relative = ($file.Substring($script:RepoRoot.Length + 1)).Replace('\', '/')
            if ($script:Exemptions -contains $relative) { continue }

            $content = Get-Content -LiteralPath $file -Raw
            if ([string]::IsNullOrWhiteSpace($content)) { continue }

            $code = [regex]::Replace($content, '<#.*?#>', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
            $code = ($code -split "`n" | ForEach-Object { ($_ -replace '#.*$', '') }) -join "`n"

            # Find $global:Name = ... writes that aren't LASTEXITCODE (which
            # is auto-managed by pwsh after every external command).
            $writes = [regex]::Matches($code, '\$global:([A-Za-z_][A-Za-z0-9_]*)\s*=')
            $nonExitWrites = @($writes | Where-Object { $_.Groups[1].Value -ne 'LASTEXITCODE' })
            if ($nonExitWrites.Count -eq 0) { continue }

            $hasAfterBlock =
                ($code -match '(?im)^\s*AfterAll\s*\{') -or
                ($code -match '(?im)^\s*AfterEach\s*\{')
            $hasFinallyRestore = $code -match '(?is)\bfinally\s*\{[^}]*?(Remove-Variable\b|\$global:[A-Za-z_][A-Za-z0-9_]*\s*=\s*\$)'
            $hasGlobalRestore =
                ($code -match '(?i)Remove-Variable\b[^`n]*-Scope\s+''?Global''?') -or
                ($code -match '(?i)Remove-Variable\b') -or
                ($code -match '(?i)Set-Variable\b[^`n]*-Scope\s+''?Global''?') -or
                ($code -match '(?i)\$global:[A-Za-z_][A-Za-z0-9_]*\s*=\s*\$(script:|global:)?[A-Za-z_][A-Za-z0-9_]*')
            if (-not (($hasAfterBlock -or $hasFinallyRestore) -and $hasGlobalRestore)) {
                $offenders.Add("$relative (missing cleanup lifecycle block and/or global restore operation)") | Out-Null
            }
        }

        $offenders -join "`n" | Should -BeNullOrEmpty -Because "every test file that mutates `$global:* (non-LASTEXITCODE) must clean it up; offenders:`n$($offenders -join "`n")"
    }

    It 'no test file falls back to the literal "/tmp" path (use [System.IO.Path]::GetTempPath() instead)' {
        $offenders = [System.Collections.Generic.List[string]]::new()
        foreach ($file in $script:AllTestFiles) {
            $relative = ($file.Substring($script:RepoRoot.Length + 1)).Replace('\', '/')
            if ($script:Exemptions -contains $relative) { continue }

            $content = Get-Content -LiteralPath $file -Raw
            if ([string]::IsNullOrWhiteSpace($content)) { continue }
            $code = [regex]::Replace($content, '<#.*?#>', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
            $code = ($code -split "`n" | ForEach-Object { ($_ -replace '#.*$', '') }) -join "`n"

            if ($code -match "(?<![A-Za-z0-9_/])'/tmp'") {
                $offenders.Add($relative) | Out-Null
            }
        }

        $offenders -join "`n" | Should -BeNullOrEmpty -Because "use [System.IO.Path]::GetTempPath() instead of literal '/tmp'; offenders:`n$($offenders -join "`n")"
    }

    It 'back-to-back test runs produce identical PassedCount (detects cross-file state leaks)' -Skip:(-not ($env:AZURE_ANALYZER_RUN_ISOLATION_META_TEST -in @('1', 'true', 'yes', 'on'))) {
        # This meta-test runs a subset of the test suite twice in the same
        # pwsh process and asserts that PassedCount is identical. A difference
        # signals that some test file is leaking state (env vars, globals,
        # module-scope variables, PSDefaultParameterValues, etc.) that affects
        # downstream tests in the second run.
        #
        # Gated behind AZURE_ANALYZER_RUN_ISOLATION_META_TEST=1 to avoid
        # exploding CI time. Enable locally via:
        #   $env:AZURE_ANALYZER_RUN_ISOLATION_META_TEST = '1'
        #   Invoke-Pester -Path tests/shared/TestIsolation.Tests.ps1

        $testPaths = @(
            (Join-Path $script:TestsRoot 'shared')
            (Join-Path $script:TestsRoot 'normalizers')
            (Join-Path $script:TestsRoot 'wrappers')
        )

        $run1 = Invoke-Pester -Path $testPaths -PassThru -Output None
        $run2 = Invoke-Pester -Path $testPaths -PassThru -Output None

        $run1.PassedCount | Should -Be $run2.PassedCount -Because "back-to-back runs must have identical PassedCount; run1=$($run1.PassedCount) run2=$($run2.PassedCount). Difference signals a state leak."
        $run1.FailedCount | Should -Be $run2.FailedCount -Because "back-to-back runs must have identical FailedCount; run1=$($run1.FailedCount) run2=$($run2.FailedCount). Difference signals a state leak."
    }
}
