#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# Regression tests for #671: New-FindingError was previously redefined in
# modules/shared/Schema.ps1 and (because AzureAnalyzer.psm1 dot-sources
# modules/shared/*.ps1 in ASCII order) the broken Schema.ps1 version
# overwrote the canonical Errors.ps1 implementation, silently bypassing
# Remove-Credentials on Reason/Remediation and skipping Category enum
# validation. This file pins the canonical contract.

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
    . (Join-Path $repoRoot 'modules' 'shared' 'Sanitize.ps1')
    . (Join-Path $repoRoot 'modules' 'shared' 'Errors.ps1')
    # Schema.ps1 must NOT redefine New-FindingError. We deliberately load it
    # AFTER Errors.ps1 here — same ASCII order the module's Get-ChildItem walk
    # produces — so any reintroduced duplicate would shadow the canonical
    # version and the assertions below would catch it.
    . (Join-Path $repoRoot 'modules' 'shared' 'Schema.ps1')
}

Describe 'New-FindingError single-definition (regression #671)' {
    It 'resolves to modules/shared/Errors.ps1, not Schema.ps1' {
        $cmd = Get-Command New-FindingError
        $cmd | Should -Not -BeNullOrEmpty
        $file = $cmd.ScriptBlock.File
        $file | Should -Not -BeNullOrEmpty
        $file | Should -Match 'Errors\.ps1$'
        $file | Should -Not -Match 'Schema\.ps1$'
    }

    It 'is defined exactly once across modules/shared' {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
        $matches = @(Get-ChildItem (Join-Path $repoRoot 'modules\shared') -Filter '*.ps1' |
            Select-String -Pattern '^function\s+New-FindingError\b')
        $matches.Count | Should -Be 1
        $matches[0].Path | Should -Match 'Errors\.ps1$'
    }
}

Describe 'New-FindingError sanitization invariant (regression #671)' {
    It 'sanitizes an AccountKey-style secret in Reason' {
        $result = New-FindingError -Source 'test' -Category 'IOFailure' `
            -Reason 'AccountKey=reallyasecret123' -Remediation 'rotate'
        ($result.Reason -match 'reallyasecret123') | Should -BeFalse
    }

    It 'sanitizes a SAS-style token in Remediation' {
        $sas = '?sig=abcDEF123ghiJKL=='
        $result = New-FindingError -Source 'test' -Category 'IOFailure' `
            -Reason 'boom' -Remediation "rotate via $sas"
        ($result.Remediation -match 'abcDEF123ghiJKL') | Should -BeFalse
    }
}

Describe 'New-FindingError Category enum enforcement (regression #671)' {
    It 'throws on an invalid Category value' {
        { New-FindingError -Source 'x' -Category 'NotARealCategory' -Reason 'r' } |
            Should -Throw -ExpectedMessage '*invalid Category*'
    }
}
