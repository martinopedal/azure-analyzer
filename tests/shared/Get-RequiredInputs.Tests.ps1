#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Preflight\Get-RequiredInputs.ps1')
}

Describe 'Get-RequiredInputs' {
    BeforeAll {
        $script:validGuid = '00000000-0000-0000-0000-000000000001'
        $script:toolDefs = @(
            [PSCustomObject]@{
                name = 'azqr'
                required_inputs = @(
                    [PSCustomObject]@{
                        name = 'SubscriptionId'
                        type = 'guid'
                        prompt = 'Enter subscription id'
                        envVar = 'AZURE_SUBSCRIPTION_ID'
                        example = '00000000-0000-0000-0000-000000000000'
                        validator = '^[0-9a-fA-F-]{36}$'
                    }
                )
            }
        )
    }

    BeforeEach {
        Remove-Item Env:\AZURE_SUBSCRIPTION_ID -ErrorAction SilentlyContinue
    }

    It 'prefers CLI over env and does not prompt' {
        $env:AZURE_SUBSCRIPTION_ID = '00000000-0000-0000-0000-000000000002'
        Mock Read-Host { throw 'Read-Host should not have been called' }

        $resolved = Get-RequiredInputs -Tools $script:toolDefs -CliValues @{ SubscriptionId = $script:validGuid }

        $resolved.SubscriptionId | Should -Be $script:validGuid
        Should -Invoke Read-Host -Times 0
    }

    It 'uses env var when CLI is absent' {
        $env:AZURE_SUBSCRIPTION_ID = '00000000-0000-0000-0000-000000000002'
        Mock Read-Host { throw 'Read-Host should not have been called' }

        $resolved = Get-RequiredInputs -Tools $script:toolDefs -CliValues @{}

        $resolved.SubscriptionId | Should -Be '00000000-0000-0000-0000-000000000002'
        Should -Invoke Read-Host -Times 0
    }

    It 'prompts in interactive mode when CLI and env are missing' {
        Mock Test-PreflightNonInteractive { return $false }
        Mock Read-Host { return $script:validGuid }

        $resolved = Get-RequiredInputs -Tools $script:toolDefs -CliValues @{}

        $resolved.SubscriptionId | Should -Be $script:validGuid
        Should -Invoke Read-Host -Times 1
    }

    It 'fails fast in non-interactive mode and lists all unresolved inputs' {
        $tools = @(
            [PSCustomObject]@{
                name = 'azqr'
                required_inputs = @(
                    [PSCustomObject]@{ name = 'SubscriptionId'; type = 'guid'; envVar = 'AZURE_SUBSCRIPTION_ID'; example = '00000000-0000-0000-0000-000000000000' },
                    [PSCustomObject]@{ name = 'ManagementGroupId'; type = 'string'; envVar = 'AZURE_MANAGEMENT_GROUP_ID'; example = 'alz-root' }
                )
            }
        )
        Mock Read-Host { throw 'Read-Host should not have been called' }

        { Get-RequiredInputs -Tools $tools -CliValues @{} -NonInteractive } |
            Should -Throw '*Unresolved required inputs*SubscriptionId*ManagementGroupId*'
        Should -Invoke Read-Host -Times 0
    }

    It 'does not require SubscriptionId when ManagementGroupId is provided' {
        $resolved = Get-RequiredInputs -Tools $script:toolDefs -CliValues @{ ManagementGroupId = 'alz-root' } -NonInteractive
        $resolved.Keys.Count | Should -Be 0
    }
}

Describe 'Test-PreflightNonInteractive' {
    It 'returns true when explicit switch is supplied' {
        Test-PreflightNonInteractive -NonInteractive | Should -BeTrue
    }

    It 'returns true when CI env var is truthy' {
        $original = $env:CI
        try {
            $env:CI = 'true'
            Test-PreflightNonInteractive | Should -BeTrue
        } finally {
            if ($null -eq $original) {
                Remove-Item Env:\CI -ErrorAction SilentlyContinue
            } else {
                $env:CI = $original
            }
        }
    }
}
