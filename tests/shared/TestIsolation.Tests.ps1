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

    It 'every test file that writes $env:* also restores it in AfterAll/AfterEach or via Remove-Item Env:' {
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

            if ($code -notmatch '\$env:[A-Z][A-Z0-9_]*\s*=') { continue }

            $hasRestore =
                ($code -match '(?im)^\s*AfterAll\s*\{') -or
                ($code -match '(?im)^\s*AfterEach\s*\{') -or
                ($code -match '(?i)Remove-Item\s+Env:') -or
                ($code -match '\$env:[A-Z][A-Z0-9_]*\s*=\s*\$script:_orig') -or
                # Inline try/finally restore: `$env:NAME = $original` or `= $saved...`
                ($code -match '(?i)finally\s*\{[^}]*\$env:[A-Z][A-Z0-9_]*\s*=\s*\$\w+')

            if (-not $hasRestore) {
                $offenders.Add($relative) | Out-Null
            }
        }

        $offenders -join "`n" | Should -BeNullOrEmpty -Because "every test file that mutates `$env:* must restore it; offenders:`n$($offenders -join "`n")"
    }

    It 'every test file that writes $global:* (other than LASTEXITCODE) restores it via Remove-Variable -Scope Global or Set-Variable -Scope Global' {
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

            $hasRestore =
                ($code -match '(?i)Remove-Variable\s+(-Name\s+)?[A-Za-z_][A-Za-z0-9_,]*\s+(-ErrorAction\s+\w+\s+)?-Scope\s+''?Global''?') -or
                ($code -match '(?i)Remove-Variable\s+(-Name\s+)?[A-Za-z_][A-Za-z0-9_,]*\s+-Scope\s+''?Global''?') -or
                ($code -match '(?i)Set-Variable\s+(-Name\s+)?[A-Za-z_][A-Za-z0-9_]*.*-Scope\s+''?Global''?')

            if (-not $hasRestore) {
                $offenders.Add($relative) | Out-Null
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
}
