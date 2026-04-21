#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-Maester.ps1'
}

Describe 'Invoke-Maester: error paths' {
    Context 'when Maester module is missing' {
        BeforeAll {
            Mock Get-Module { return $null }
            $result = & $script:Wrapper
        }

        It 'returns Status = Skipped' {
            $result.Status | Should -Be 'Skipped'
        }

        It 'returns empty Findings' {
            @($result.Findings).Count | Should -Be 0
        }

        It 'includes message about Maester not installed' {
            $result.Message | Should -Match 'not installed|not found'
        }

        It 'sets Source to maester' {
            $result.Source | Should -Be 'maester'
        }

        It 'includes SchemaVersion 1.0 in the v1 envelope' {
            $result.SchemaVersion | Should -Be '1.0'
        }
    }
}

Describe 'Invoke-Maester: success mapping' {
    BeforeAll {
        $fixBlock = @'
Use Conditional Access policy.
```powershell
New-MgIdentityConditionalAccessPolicy -DisplayName ''Require MFA for admins''
```
'@
        $global:MaesterContainer = [pscustomobject]@{
            Result = @(
                [pscustomobject]@{
                    Name           = 'MFA is not enforced for all administrators'
                    Result         = 'Failed'
                    Tag            = @('Critical', 'CIS-MS365-1.1.1', 'EIDSCA-AT01', 'MITRE-TA0001', 'MITRE-T1078', 'spn:22222222-2222-2222-2222-222222222222')
                    TestId         = 'MT.1001'
                    Block          = [pscustomobject]@{ Name = 'Identity' }
                    ErrorRecord    = @('MFA was missing for 3 admin accounts')
                    LearnMoreUrl   = 'https://learn.microsoft.com/entra/identity/authentication/concept-mfa-howitworks'
                    SourceUri      = 'https://github.com/maester365/maester/blob/main/tests/MT.1001.Tests.ps1'
                    HowToFix       = $fixBlock
                    ServicePrincipalIds = @('22222222-2222-2222-2222-222222222222')
                },
                [pscustomobject]@{
                    Name         = 'Self-service password reset is enabled'
                    Result       = 'Passed'
                    Tag          = @('Info', 'NIST-800-53-IA-2')
                    TestId       = 'MT.3001'
                    Block        = [pscustomobject]@{ Name = 'Identity' }
                    LearnMoreUrl = 'https://learn.microsoft.com/entra/identity/authentication/concept-sspr-howitworks'
                    SourceUri    = 'https://github.com/maester365/maester/blob/main/tests/MT.3001.Tests.ps1'
                    HowToFix     = ''
                }
            )
        }

        function global:Invoke-Maester {
            [CmdletBinding()]
            param(
                [switch]$PassThru,
                [switch]$Quiet
            )
            return $global:MaesterContainer
        }

        function global:Get-MgContext {
            [CmdletBinding()]
            param()
            return [pscustomobject]@{ TenantId = '11111111-1111-1111-1111-111111111111' }
        }

        Mock Get-Module {
            param([string]$Name, [switch]$ListAvailable)
            if ($Name -eq 'Maester') {
                return [pscustomobject]@{ Name = 'Maester'; Version = [version]'1.0.0' }
            }
            return $null
        }
        Mock Import-Module { return $null } -ParameterFilter { $Name -eq 'Maester' }
        Mock Get-Command {
            param([string]$Name)
            if ($Name -eq 'Invoke-Maester') { return [pscustomobject]@{ Name = 'Invoke-Maester' } }
            if ($Name -eq 'Get-MgContext') { return [pscustomobject]@{ Name = 'Get-MgContext' } }
            return $null
        }
        $script:Result = & $script:Wrapper
    }

    AfterAll {
        if (Test-Path Function:\global:Invoke-Maester) {
            Remove-Item Function:\global:Invoke-Maester -ErrorAction SilentlyContinue
        }
        if (Test-Path Function:\global:Get-MgContext) {
            Remove-Item Function:\global:Get-MgContext -ErrorAction SilentlyContinue
        }
        Remove-Variable -Name MaesterContainer -Scope Global -ErrorAction SilentlyContinue
    }

    It 'returns Success and findings from Maester output' {
        $script:Result.Status | Should -Be 'Success'
        @($script:Result.Findings).Count | Should -Be 2
    }

    It 'emits tenant metadata at wrapper level' {
        $script:Result.TenantId | Should -Be '11111111-1111-1111-1111-111111111111'
        $script:Result.ToolVersion | Should -Be '1.0.0'
    }

    It 'maps Schema 2.2 precursor fields in wrapper output' {
        $first = $script:Result.Findings[0]
        $first.TestId | Should -Be 'MT.1001'
        $first.Pillar | Should -Be 'Security'
        $first.DeepLinkUrl | Should -Be 'https://maester.dev/docs/tests/MT.1001'
        $first.ToolVersion | Should -Be '1.0.0'
        @($first.Frameworks).Count | Should -Be 2
        $first.BaselineTags | Should -Contain 'CIS-MS365-1.1.1'
        $first.BaselineTags | Should -Contain 'EIDSCA-AT01'
        $first.MitreTactics | Should -Contain 'TA0001'
        $first.MitreTechniques | Should -Contain 'T1078'
        $first.EntityRefs | Should -Contain '11111111-1111-1111-1111-111111111111'
        $first.EntityRefs | Should -Contain '22222222-2222-2222-2222-222222222222'
        @($first.RemediationSnippets).Count | Should -BeGreaterThan 0
        $first.RemediationSnippets[0].language | Should -Be 'powershell'
        $first.EvidenceUris | Should -Contain 'https://github.com/maester365/maester/blob/main/tests/MT.1001.Tests.ps1'
    }
}
