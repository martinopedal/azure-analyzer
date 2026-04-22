#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Guard for audit category 2 (post-#473 consistency sweep):
#
#   Wrapper modules under modules/ must NOT carry private, no-op
#   re-implementations of Invoke-WithRetry that would shadow the canonical
#   implementation in modules/shared/Retry.ps1.
#
#   Each wrapper is allowed to declare a defensive fallback, but it MUST
#   be guarded by a `if (-not (Get-Command Invoke-WithRetry ...))` block
#   so the shared implementation always wins when both are loaded. A bare
#   top-level `function Invoke-WithRetry { ... }` would shadow the real
#   retry semantics and silently degrade transient-error handling to a
#   single-shot call - exactly the silent-failure class this sweep
#   targets.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:WrapperFiles = Get-ChildItem -Path (Join-Path $script:RepoRoot 'modules') -Filter 'Invoke-*.ps1' -Recurse -File
    $script:SinkFiles = Get-ChildItem -Path (Join-Path $script:RepoRoot 'modules' 'sinks') -Filter '*.ps1' -File -ErrorAction SilentlyContinue
    $script:Files = @($script:WrapperFiles) + @($script:SinkFiles) | Where-Object { $_ }
}

Describe 'Retry consolidation - no unguarded Invoke-WithRetry shims' {

    It 'every wrapper / sink that defines Invoke-WithRetry guards it behind a Get-Command check' {
        $offenders = [System.Collections.Generic.List[string]]::new()

        foreach ($file in $script:Files) {
            $text = Get-Content -LiteralPath $file.FullName -Raw

            $defMatches = [regex]::Matches($text, '(?m)^\s*function\s+Invoke-WithRetry\b')
            if ($defMatches.Count -eq 0) { continue }

            foreach ($m in $defMatches) {
                # Look at the preceding 200 characters for an enclosing guard.
                $startIndex = [Math]::Max(0, $m.Index - 200)
                $window = $text.Substring($startIndex, $m.Index - $startIndex)

                $hasGuard = $window -match "if\s*\(\s*-not\s*\(\s*Get-Command\s+Invoke-WithRetry"
                if (-not $hasGuard) {
                    $line = ($text.Substring(0, $m.Index) -split "`n").Count
                    $offenders.Add(("{0}:{1}" -f $file.FullName, $line))
                }
            }
        }

        $offenders.Count | Should -Be 0 -Because (
            "Wrapper-private Invoke-WithRetry redefinitions must be guarded " +
            "by a Get-Command check so the shared modules/shared/Retry.ps1 " +
            "implementation always wins. Offenders:`n" + ($offenders -join "`n")
        )
    }

    It 'shared Retry.ps1 exposes Invoke-WithRetry as the canonical implementation' {
        $retryPath = Join-Path $script:RepoRoot 'modules' 'shared' 'Retry.ps1'
        Test-Path $retryPath | Should -BeTrue

        # Loading the shared file should make the function available, and
        # importing the public module should NOT replace it with a wrapper
        # shim.
        Get-Module AzureAnalyzer -ErrorAction SilentlyContinue | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $script:RepoRoot 'AzureAnalyzer.psd1') -Force

        # Invoke-WithRetry is internal to the module session state, not
        # exported. Query it via the module's session block to confirm it
        # resolves to the shared implementation rather than a wrapper shim.
        $module = Get-Module AzureAnalyzer
        $module | Should -Not -BeNullOrEmpty

        $cmd = & $module { Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue }
        $cmd | Should -Not -BeNullOrEmpty

        $sourceFile = $cmd.ScriptBlock.File
        if ($sourceFile) {
            ([string]$sourceFile).Replace('\','/') | Should -Match 'modules/shared/Retry\.ps1$' -Because (
                "Invoke-WithRetry must resolve to modules/shared/Retry.ps1, " +
                "not a wrapper-private shim. Resolved to: $sourceFile"
            )
        }
    }
}
