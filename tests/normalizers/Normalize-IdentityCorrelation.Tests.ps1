#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-IdentityCorrelation.ps1')
}

Describe 'Normalize-IdentityCorrelation' {
    Context 'FindingRow emission' {
        BeforeAll {
            $script:input = Get-Content (Join-Path $PSScriptRoot '..\fixtures\identity-graph\identity-correlation-output.json') -Raw | ConvertFrom-Json
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
                $r.SchemaVersion | Should -Be '2.2'
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
            $user.Title | Should -Be 'User identity appears in cross-tenant workload chain'
        }

        It 'populates Schema 2.2 identity ETL fields including MITRE metadata' {
            $row = $script:rows | Where-Object { $_.EntityType -eq 'ServicePrincipal' } | Select-Object -First 1
            $row.Pillar | Should -Be 'Security'
            $row.Impact | Should -Be 'High'
            $row.Effort | Should -Be 'Medium'
            $row.DeepLinkUrl | Should -Match 'entra\.microsoft\.com'
            $row.ToolVersion | Should -Be 'identity-correlator-fixture'
            @($row.Frameworks).Count | Should -Be 2
            $row.Frameworks[0].Name | Should -Be 'NIST 800-53'
            $row.Frameworks[1].Name | Should -Be 'CIS Controls v8'
            $row.MitreTactics | Should -Contain 'TA0001'
            $row.MitreTactics | Should -Contain 'TA0006'
            $row.MitreTactics | Should -Contain 'TA0008'
            $row.MitreTechniques | Should -Contain 'T1078'
            $row.MitreTechniques | Should -Contain 'T1550'
            $row.MitreTechniques | Should -Contain 'T1021'
            @($row.RemediationSnippets).Count | Should -BeGreaterThan 0
            $row.RemediationSnippets[0].language | Should -Be 'text'
            @($row.EvidenceUris).Count | Should -BeGreaterThan 0
            $row.EvidenceUris | Should -Contain 'https://learn.microsoft.com/entra/identity/conditional-access/concept-workload-identity'
            $row.BaselineTags | Should -Contain 'identity-correlator'
            $row.EntityRefs | Should -Contain $row.EntityId
            $row.EntityRefs | Should -Contain 'objectid:11111111-2222-3333-4444-555555555555'
        }

        It 'creates Entra deep link and entity refs for user findings' {
            $user = $script:rows | Where-Object { $_.EntityType -eq 'User' }
            $user.DeepLinkUrl | Should -Match 'UserProfileMenuBlade'
            $user.EntityRefs | Should -Contain 'objectid:99999999-aaaa-bbbb-cccc-dddddddddddd'
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
