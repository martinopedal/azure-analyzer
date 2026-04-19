#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-IdentityCorrelation.ps1')
}

Describe 'Normalize-IdentityCorrelation' {
    Context 'FindingRow emission' {
        BeforeAll {
            $script:input = [PSCustomObject]@{
                Status   = 'Success'
                RunId    = 'test-run-001'
                Findings = @(
                    [PSCustomObject]@{
                        Id            = 'f1'
                        EntityId      = '11111111-1111-1111-1111-111111111111'
                        EntityType    = 'ServicePrincipal'
                        Title         = 'SPN with excessive permissions'
                        Compliant     = $false
                        Severity      = 'High'
                        Category      = 'Identity'
                        Detail        = 'Has Owner on 3 subscriptions'
                        Remediation   = 'Reduce scope'
                        LearnMoreUrl  = ''
                        ResourceId    = ''
                    },
                    [PSCustomObject]@{
                        Id            = 'f2'
                        EntityId      = '22222222-2222-2222-2222-222222222222'
                        PrincipalType = 'User'
                        Title         = 'User with stale credentials'
                        Compliant     = $false
                        Severity      = 'Medium'
                        Category      = 'Identity'
                        Detail        = 'Last sign-in 180 days ago'
                        Remediation   = 'Disable account'
                        LearnMoreUrl  = ''
                        ResourceId    = ''
                    }
                )
            }
            $script:rows = @(Normalize-IdentityCorrelation -ToolResult $script:input)
        }

        It 'emits one FindingRow per input finding' {
            $script:rows.Count | Should -Be 2
        }

        It 'each row has all required FindingRow fields' {
            foreach ($r in $script:rows) {
                $r.PSObject.Properties['Id'] | Should -Not -BeNullOrEmpty
                $r.PSObject.Properties['Source'] | Should -Not -BeNullOrEmpty
                $r.PSObject.Properties['EntityId'] | Should -Not -BeNullOrEmpty
                $r.PSObject.Properties['EntityType'] | Should -Not -BeNullOrEmpty
                $r.PSObject.Properties['Title'] | Should -Not -BeNullOrEmpty
                $r.PSObject.Properties['SchemaVersion'] | Should -Not -BeNullOrEmpty
                $r.SchemaVersion | Should -Be '2.0'
                $r.Source | Should -Be 'identity-correlator'
            }
        }

        It 'canonicalizes ServicePrincipal entity IDs' {
            $spn = $script:rows | Where-Object { $_.EntityType -eq 'ServicePrincipal' }
            $spn | Should -Not -BeNullOrEmpty
            $spn.EntityId | Should -Match '^appId:[0-9a-f-]+$'
        }

        It 'canonicalizes User entity IDs' {
            $user = $script:rows | Where-Object { $_.EntityType -eq 'User' }
            $user | Should -Not -BeNullOrEmpty
            $user.EntityId | Should -Match '^objectId:[0-9a-f-]+$'
        }

        It 'detects User EntityType from PrincipalType field' {
            $user = $script:rows | Where-Object { $_.EntityType -eq 'User' }
            $user.Title | Should -Be 'User with stale credentials'
        }
    }

    Context 'error handling' {
        It 'returns empty array for failed tool output' {
            $r = @(Normalize-IdentityCorrelation -ToolResult ([PSCustomObject]@{ Status = 'Failed'; Findings = @() }))
            $r.Count | Should -Be 0
        }

        It 'returns empty array for null findings' {
            $r = @(Normalize-IdentityCorrelation -ToolResult ([PSCustomObject]@{ Status = 'Success'; Findings = $null }))
            $r.Count | Should -Be 0
        }
    }
}
