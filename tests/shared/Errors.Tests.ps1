#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# Tests for modules/shared/Errors.ps1 — the New-FindingError /
# Format-FindingErrorMessage / Write-FindingError trio that backs Cat 4 of the
# post-#473 consistency sweep.

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
    . (Join-Path $repoRoot 'modules' 'shared' 'Sanitize.ps1')
    . (Join-Path $repoRoot 'modules' 'shared' 'Errors.ps1')
}

Describe 'New-FindingError' {
    It 'returns a PSCustomObject with all required fields' {
        $err = New-FindingError -Source 'orchestrator' -Category 'InvalidParameter' `
            -Reason 'because' -Remediation 'do this'
        $err | Should -Not -BeNullOrEmpty
        $err.Source       | Should -Be 'orchestrator'
        $err.Category     | Should -Be 'InvalidParameter'
        $err.Reason       | Should -Be 'because'
        $err.Remediation  | Should -Be 'do this'
        $err.TimestampUtc | Should -Not -BeNullOrEmpty
    }

    It 'rejects an unknown Category' {
        { New-FindingError -Source 'orchestrator' -Category 'NotARealCategory' -Reason 'x' } `
            | Should -Throw -ExpectedMessage '*invalid Category*'
    }

    It 'sanitizes secrets in Reason / Details / Remediation' {
        $secret = 'AccountKey=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=='
        $err = New-FindingError -Source 'wrapper:test' -Category 'IOFailure' `
            -Reason "boom $secret" -Remediation "rotate $secret" -Details "see $secret in log"
        $err.Reason      | Should -Not -Match 'AccountKey=AAAA'
        $err.Remediation | Should -Not -Match 'AccountKey=AAAA'
        $err.Details     | Should -Not -Match 'AccountKey=AAAA'
    }
}

Describe 'Format-FindingErrorMessage' {
    It 'includes Source, Category, Reason, and Action when remediation is set' {
        $err  = New-FindingError -Source 'orchestrator' -Category 'InvalidParameter' `
            -Reason '-Foo conflicts with -Bar.' -Remediation 'Pass only one.'
        $msg  = Format-FindingErrorMessage $err
        $msg  | Should -Match '\[orchestrator\]'
        $msg  | Should -Match 'InvalidParameter'
        $msg  | Should -Match '-Foo conflicts with -Bar\.'
        $msg  | Should -Match 'Action: Pass only one\.'
    }

    It 'omits the Action: suffix when no remediation is supplied' {
        $err = New-FindingError -Source 'shared:Retry' -Category 'TransientFailure' -Reason 'flaky.'
        $msg = Format-FindingErrorMessage $err
        $msg | Should -Not -Match 'Action:'
    }
}

Describe 'Write-FindingError' {
    It 'emits the formatted message as a warning' {
        $err = New-FindingError -Source 'orchestrator' -Category 'InvalidParameter' `
            -Reason 'bad input.' -Remediation 'fix it.'
        $warnings = @()
        Write-FindingError -FindingError $err -WarningVariable warnings -WarningAction SilentlyContinue
        ($warnings -join "`n") | Should -Match 'bad input\.'
        ($warnings -join "`n") | Should -Match 'Action: fix it\.'
    }
}
