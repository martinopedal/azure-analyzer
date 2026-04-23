#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# Regression tests for #529 — security-regression: New-FindingError
# double-definition silently bypassed Remove-Credentials sanitization. The fix
# (PR #683 / #671) removed the duplicate from modules/shared/Schema.ps1 and made
# modules/shared/Errors.ps1 the sole canonical definition.
#
# These tests pin the contract end-to-end: only one definition exists across
# modules/shared, the canonical version routes Reason / Remediation / Details
# through Remove-Credentials, and the new collision detector exposes a function
# tests can call to flag any future redefinition.

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
    . (Join-Path $repoRoot 'modules' 'shared' 'Sanitize.ps1')
    . (Join-Path $repoRoot 'modules' 'shared' 'Errors.ps1')
    . (Join-Path $repoRoot 'modules' 'shared' 'FunctionCollision.ps1')
}

Describe 'New-FindingError single definition (regression #529)' {
    It 'is defined exactly once across modules/shared' {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
        $hits = @(Get-ChildItem (Join-Path $repoRoot 'modules\shared') -Filter '*.ps1' -Recurse |
            Select-String -Pattern '^function\s+New-FindingError\b')
        $hits.Count | Should -Be 1
        $hits[0].Path | Should -Match 'Errors\.ps1$'
    }

    It 'resolves to modules/shared/Errors.ps1 when shared helpers are dot-sourced in ASCII order' {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
        # Reproduce the module load order: dot-source the entire modules/shared
        # tree alphabetically (the same Get-ChildItem walk AzureAnalyzer.psm1
        # does) inside a clean child pwsh, then ask which file defined the
        # winning New-FindingError.
        $script = @"
`$ErrorActionPreference = 'Stop'
Get-ChildItem -Path '$($repoRoot.Path -replace "'","''")\modules\shared' -Filter '*.ps1' -Recurse |
    ForEach-Object { . `$_.FullName }
(Get-Command New-FindingError).ScriptBlock.File
"@
        $resolvedFile = pwsh -NoProfile -Command $script
        $resolvedFile | Should -Match 'Errors\.ps1$'
    }
}

Describe 'New-FindingError sanitization contract (regression #529)' {
    It 'redacts AccountKey-style secrets from Reason' {
        $r = New-FindingError -Source 't' -Category 'IOFailure' `
            -Reason 'AccountKey=reallyasecret123' -Remediation 'rotate'
        $r.Reason | Should -Not -Match 'reallyasecret123'
        $r.Reason | Should -Match '\[REDACTED\]'
    }

    It 'redacts SAS sig= tokens from Remediation' {
        $r = New-FindingError -Source 't' -Category 'IOFailure' `
            -Reason 'boom' -Remediation 'check ?sig=ABC123DEF456XYZ789QQ'
        $r.Remediation | Should -Not -Match 'ABC123DEF456XYZ789QQ'
        $r.Remediation | Should -Match '\[REDACTED\]'
    }

    It 'redacts Bearer tokens from Details' {
        $r = New-FindingError -Source 't' -Category 'IOFailure' `
            -Reason 'boom' -Details 'Authorization: Bearer eyJabcDEF.ghiJKL.mnoPQR'
        $r.Details | Should -Not -Match 'eyJabcDEF\.ghiJKL\.mnoPQR'
        $r.Details | Should -Match '\[REDACTED\]'
    }

    It 'rejects bogus Category values' {
        { New-FindingError -Source 'x' -Category 'NotARealCategory' -Reason 'r' } |
            Should -Throw -ExpectedMessage '*invalid Category*'
    }
}

Describe 'Shared function collision detector (regression #529)' {
    It 'is exposed as Test-AzureAnalyzerSharedFunctionCollisions after dot-sourcing FunctionCollision.ps1' {
        Get-Command Test-AzureAnalyzerSharedFunctionCollisions -ErrorAction Stop |
            Should -Not -BeNullOrEmpty
    }

    It 'does not report New-FindingError as a collision (regression #529)' {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
        $files = @(Get-ChildItem (Join-Path $repoRoot 'modules\shared') -Filter '*.ps1' -Recurse)
        $collisions = @(Test-AzureAnalyzerSharedFunctionCollisions -Files $files -WarningAction SilentlyContinue)
        $names = $collisions | ForEach-Object { $_.Key }
        $names | Should -Not -Contain 'New-FindingError'
    }

    It 'flags duplicate function names when present (synthetic fixture)' {
        $tmpDir = Join-Path $TestDrive ("aa-collide-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $tmpDir | Out-Null
        'function Foo-Bar { 1 }' | Set-Content -Path (Join-Path $tmpDir 'A.ps1')
        'function Foo-Bar { 2 }' | Set-Content -Path (Join-Path $tmpDir 'B.ps1')
        $files = @(Get-ChildItem $tmpDir -Filter '*.ps1')
        $collisions = @(Test-AzureAnalyzerSharedFunctionCollisions -Files $files -WarningAction SilentlyContinue)
        $collisions.Count | Should -Be 1
        $collisions[0].Key | Should -Be 'Foo-Bar'
    }

    It 'ignores guarded fallback shims wrapped in if (-not (Get-Command X))' {
        $tmpDir = Join-Path $TestDrive ("aa-guard-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $tmpDir | Out-Null
        'function Foo-Real { 1 }' | Set-Content -Path (Join-Path $tmpDir 'A.ps1')
        'if (-not (Get-Command Foo-Real -ErrorAction SilentlyContinue)) { function Foo-Real { 2 } }' |
            Set-Content -Path (Join-Path $tmpDir 'B.ps1')
        $files = @(Get-ChildItem $tmpDir -Filter '*.ps1')
        $collisions = @(Test-AzureAnalyzerSharedFunctionCollisions -Files $files -WarningAction SilentlyContinue)
        $collisions.Count | Should -Be 0
    }

    It 'flags duplicate function names inside unguarded if blocks' {
        $tmpDir = Join-Path $TestDrive ("collision-test-unguarded-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $tmpDir | Out-Null
        'function Foo-Conditional { 1 }' | Set-Content -Path (Join-Path $tmpDir 'A.ps1')
        'if ($true) { function Foo-Conditional { 2 } }' |
            Set-Content -Path (Join-Path $tmpDir 'B.ps1')
        $files = @(Get-ChildItem $tmpDir -Filter '*.ps1')
        $collisions = @(Test-AzureAnalyzerSharedFunctionCollisions -Files $files -WarningAction SilentlyContinue)
        $collisions.Count | Should -Be 1
        $collisions[0].Key | Should -Be 'Foo-Conditional'
    }
}
