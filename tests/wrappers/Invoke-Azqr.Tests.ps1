#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# See tests/wrappers/Invoke-AlzQueries.Tests.ps1 header -- single-file run guard.
$env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = '1'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-Azqr.ps1'
}

Describe 'Invoke-Azqr' {
    Context 'when azqr CLI is missing' {
        BeforeAll {
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'azqr' }
            $result = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000000'
        }

        It 'returns Status = Skipped' {
            $result.Status | Should -Be 'Skipped'
        }

        It 'returns empty Findings' {
            @($result.Findings).Count | Should -Be 0
        }

        It 'includes a message about azqr not installed' {
            $result.Message | Should -Match 'not installed'
        }

        It 'sets Source to azqr' {
            $result.Source | Should -Be 'azqr'
        }

        It 'includes SchemaVersion 1.0 in the v1 envelope' {
            $result.SchemaVersion | Should -Be '1.0'
        }
    }

    Context 'when azqr CLI is available' {
        BeforeEach {
            function global:azqr {
                param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Arguments)
                $joined = $Arguments -join ' '
                if ($joined -eq '--version') { return 'azqr version 2.6.1' }
                if ($Arguments[0] -eq 'scan') { return '' }
                throw "unexpected azqr invocation: $joined"
            }

            Mock Get-Command { return @{ Name = 'azqr' } } -ParameterFilter { $Name -eq 'azqr' }
        }

        AfterEach {
            if (Test-Path 'Function:global:azqr') {
                Remove-Item 'Function:global:azqr' -ErrorAction SilentlyContinue
            }
        }

        It 'captures Schema 2.2 passthrough fields into v1 findings' {
            $outputPath = Join-Path $TestDrive 'azqr-out'
            $null = New-Item -ItemType Directory -Path $outputPath -Force

            $payload = @(
                [pscustomobject]@{
                    Id                = 'azqr-sec-001'
                    ResourceId        = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-test/providers/Microsoft.Compute/virtualMachines/vm-test'
                    Category          = 'Security'
                    RecommendationId  = 'AZQR.SEC.001'
                    Recommendation    = 'Enable encryption'
                    Compliant         = $false
                    Severity          = 'High'
                    Detail            = 'detail'
                    LearnMoreUrl      = 'https://learn.microsoft.com/example'
                    Remediation       = 'Do thing'
                    Impact            = 'High'
                    Effort            = 'Medium'
                    DeepLinkUrl       = 'https://portal.azure.com/#resource'
                    MitreTactics      = @('TA0001')
                    MitreTechniques   = @('T1078')
                    RemediationSnippets = @(@{ language = 'AzureCLI'; code = 'az vm encryption enable ...' })
                }
            ) | ConvertTo-Json -Depth 10
            Set-Content -Path (Join-Path $outputPath 'azqr-results.json') -Value $payload -NoNewline

            $result = & $script:Wrapper -SubscriptionId '00000000-0000-0000-0000-000000000001' -OutputPath $outputPath

            $result.Status | Should -Be 'Success'
            $result.ToolVersion | Should -Be '2.6.1'
            @($result.Findings).Count | Should -Be 1
            $result.Findings[0].Pillar | Should -Be 'Security'
            $result.Findings[0].RecommendationId | Should -Be 'AZQR.SEC.001'
            $result.Findings[0].Frameworks[0].kind | Should -Be 'WAF'
            $result.Findings[0].Frameworks[0].controlId | Should -Be 'Security'
            $result.Findings[0].MitreTactics | Should -Contain 'TA0001'
            $result.Findings[0].MitreTechniques | Should -Contain 'T1078'
            $result.Findings[0].ToolVersion | Should -Be '2.6.1'
        }
    }
}

