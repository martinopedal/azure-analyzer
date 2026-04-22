#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Regression guard for the LASTEXITCODE audit follow-up to issue #470.
#
# modules/Invoke-KubeBench.ps1 invokes `kubectl wait` and `kubectl logs`
# back-to-back inside the per-cluster scan loop. Until this guard landed, both
# calls were unchecked: a `wait` timeout silently fell through to a `logs`
# call that could capture a partially-written or empty stream, and a `logs`
# RBAC failure was masked by the downstream IsNullOrWhiteSpace check.
#
# This test asserts that each `& kubectl ... wait ...` and `& kubectl ... logs`
# native invocation inside the wrapper is followed within a small window by an
# `if ($LASTEXITCODE -ne 0)` branch. It is text/regex based on purpose: the
# whole point is to catch silent removal of the check, not to exercise the
# kubectl runtime path (which is gated by ARG cluster discovery).

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:WrapperPath = Join-Path $script:RepoRoot 'modules' 'Invoke-KubeBench.ps1'
    $script:WrapperText = Get-Content -LiteralPath $script:WrapperPath -Raw
}

Describe 'Invoke-KubeBench LASTEXITCODE audit guard (#470 follow-up)' {
    It 'wrapper file exists' {
        Test-Path $script:WrapperPath | Should -BeTrue
    }

    It 'every `kubectl wait` invocation is followed by a LASTEXITCODE check within 6 lines' {
        $lines = $script:WrapperText -split "`r?`n"
        $offenders = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*&\s*kubectl\b.*\bwait\b') {
                $window = $lines[($i + 1)..([Math]::Min($lines.Count - 1, $i + 6))] -join "`n"
                if ($window -notmatch '\$LASTEXITCODE\s*-ne\s*0') {
                    $offenders.Add(("{0}:{1}" -f $script:WrapperPath, ($i + 1)))
                }
            }
        }
        $offenders.Count | Should -Be 0 -Because (
            "Each kubectl wait call must be guarded by an exit-code check " +
            "to avoid silently treating a wait timeout as a successful scan. Offenders:`n" + ($offenders -join "`n")
        )
    }

    It 'every `kubectl logs` invocation is followed by a LASTEXITCODE check within 6 lines' {
        $lines = $script:WrapperText -split "`r?`n"
        $offenders = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*&\s*kubectl\b.*\blogs\b') {
                $window = $lines[($i + 1)..([Math]::Min($lines.Count - 1, $i + 6))] -join "`n"
                if ($window -notmatch '\$LASTEXITCODE\s*-ne\s*0') {
                    $offenders.Add(("{0}:{1}" -f $script:WrapperPath, ($i + 1)))
                }
            }
        }
        $offenders.Count | Should -Be 0 -Because (
            "Each kubectl logs call must be guarded by an exit-code check " +
            "so RBAC / pod-evicted failures surface instead of being masked by the " +
            "downstream IsNullOrWhiteSpace check. Offenders:`n" + ($offenders -join "`n")
        )
    }

    It 'wrapper loads modules/shared/Errors.ps1 so Write-FindingError is callable' {
        $script:WrapperText | Should -Match "Join-Path\s+\`$PSScriptRoot\s+'shared'\s+'Errors\.ps1'"
        $script:WrapperText | Should -Match 'Get-Command\s+Write-FindingError'
    }
}
