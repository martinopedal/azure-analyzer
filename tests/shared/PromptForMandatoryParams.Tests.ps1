#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Read-MandatoryScannerParam' {
    BeforeAll {
        $script:modulePath = Join-Path $PSScriptRoot '..' '..' 'modules' 'shared' 'PromptForMandatoryParams.ps1'
        . $script:modulePath
        $script:savedCi = $env:CI
        $script:savedEnvVar = $env:AA_TEST_PARAM_426
    }

    AfterAll {
        if ($null -eq $script:savedCi) {
            Remove-Item Env:CI -ErrorAction SilentlyContinue
        } else {
            $env:CI = $script:savedCi
        }
        if ($null -eq $script:savedEnvVar) {
            Remove-Item Env:AA_TEST_PARAM_426 -ErrorAction SilentlyContinue
        } else {
            $env:AA_TEST_PARAM_426 = $script:savedEnvVar
        }
    }

    BeforeEach {
        Remove-Item Env:CI -ErrorAction SilentlyContinue
        Remove-Item Env:AA_TEST_PARAM_426 -ErrorAction SilentlyContinue
    }

    It 'returns env-var value when fallback env is set (env precedence)' {
        $env:AA_TEST_PARAM_426 = 'env-value-xyz'
        $result = Read-MandatoryScannerParam -ScannerName 'azqr' -ParamName 'SubscriptionId' -EnvVarFallback 'AA_TEST_PARAM_426'
        $result | Should -Be 'env-value-xyz'
    }

    It 'returns $null and warns when CI=true and no env var supplied' {
        $env:CI = 'true'
        $warnings = @()
        $result = Read-MandatoryScannerParam -ScannerName 'gitleaks' -ParamName 'Repository' -EnvVarFallback 'AA_TEST_PARAM_426' -WarningVariable warnings -WarningAction SilentlyContinue
        $result | Should -BeNullOrEmpty
        ($warnings -join ' ') | Should -Match 'gitleaks'
        ($warnings -join ' ') | Should -Match 'Repository'
    }

    It 'prompts via Read-Host when interactive and env var is missing' {
        Mock -CommandName Read-Host -MockWith { 'prompted-value' }
        Mock -CommandName Test-MandatoryParamInteractive -MockWith { $true }
        $result = Read-MandatoryScannerParam -ScannerName 'azqr' -ParamName 'TenantId'
        $result | Should -Be 'prompted-value'
    }

    It 'returns $null when interactive prompt is left blank' {
        Mock -CommandName Read-Host -MockWith { '' }
        Mock -CommandName Test-MandatoryParamInteractive -MockWith { $true }
        $warnings = @()
        $result = Read-MandatoryScannerParam -ScannerName 'azqr' -ParamName 'TenantId' -WarningVariable warnings -WarningAction SilentlyContinue
        $result | Should -BeNullOrEmpty
        ($warnings -join ' ') | Should -Match 'TenantId'
    }
}

Describe 'Test-MandatoryParamInteractive' {
    BeforeAll {
        $script:modulePath = Join-Path $PSScriptRoot '..' '..' 'modules' 'shared' 'PromptForMandatoryParams.ps1'
        . $script:modulePath
        $script:savedCi = $env:CI
    }

    AfterAll {
        if ($null -eq $script:savedCi) {
            Remove-Item Env:CI -ErrorAction SilentlyContinue
        } else {
            $env:CI = $script:savedCi
        }
    }

    It 'returns $false when CI env var is "true"' {
        $env:CI = 'true'
        Test-MandatoryParamInteractive | Should -BeFalse
    }

    It 'returns $false when CI env var is "1"' {
        $env:CI = '1'
        Test-MandatoryParamInteractive | Should -BeFalse
    }
}
