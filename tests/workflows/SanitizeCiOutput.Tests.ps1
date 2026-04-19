#Requires -Version 7.4
<#
Tests for scripts/Sanitize-CiOutput.ps1 — the cross-platform sanitizer used
by ci-failure-watchdog.yml + ci-health-digest.yml issue bodies. Covers the
five token classes the watchdog's bash sed pipeline already redacts (PAT,
OAuth, Bearer, AccountKey, SAS) plus the GH fine-grained PAT format.
#>

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Sanitize-CiOutput.ps1'
    if (-not (Test-Path $script:ScriptPath)) {
        throw "Sanitizer script missing at $script:ScriptPath"
    }
}

Describe 'Sanitize-CiOutput.ps1' {
    It 'redacts a classic GitHub PAT' {
        $token = 'ghp_' + ('a' * 36)
        $out = & $script:ScriptPath -Text "Token leak: $token in log"
        $out | Should -Not -Match 'ghp_[A-Za-z0-9]{36}'
        $out | Should -Match '\[GITHUB-PAT-REDACTED\]'
    }

    It 'redacts a fine-grained GitHub PAT' {
        $token = 'github_pat_' + ('A' * 82)
        $out = & $script:ScriptPath -Text "PAT=$token"
        $out | Should -Not -Match 'github_pat_'
        $out | Should -Match '\[GITHUB-PAT-REDACTED\]'
    }

    It 'redacts a Bearer token' {
        $out = & $script:ScriptPath -Text 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig'
        $out | Should -Not -Match 'eyJhbGciOiJIUzI1NiJ9'
        $out | Should -Match '\[REDACTED\]'
    }

    It 'redacts an Azure Storage AccountKey' {
        $out = & $script:ScriptPath -Text 'DefaultEndpointsProtocol=https;AccountKey=abcd1234ZZZ==;EndpointSuffix=core.windows.net'
        $out | Should -Not -Match 'abcd1234ZZZ'
        $out | Should -Match 'AccountKey=\[REDACTED\]'
    }

    It 'redacts a SAS signature' {
        $out = & $script:ScriptPath -Text 'https://example.blob.core.windows.net/c?sv=2024-01-01&sig=ABCDEFGHIJKLMNOPQ%2FZZ&se=2026-01-01'
        $out | Should -Not -Match 'ABCDEFGHIJKLMNOPQ'
        $out | Should -Match 'sig=\[REDACTED\]'
    }

    It 'is a no-op for clean text' {
        $clean = 'PR Review Gate failed on push to main: tests/ExampleTest.Tests.ps1 line 42'
        $out = & $script:ScriptPath -Text $clean
        $out | Should -Be $clean
    }

    It 'accepts piped stdin input' {
        $token = 'ghp_' + ('b' * 36)
        $out = "leak $token here" | & $script:ScriptPath
        $out | Should -Match '\[GITHUB-PAT-REDACTED\]'
        $out | Should -Not -Match 'ghp_[A-Za-z0-9]{36}'
    }
}
