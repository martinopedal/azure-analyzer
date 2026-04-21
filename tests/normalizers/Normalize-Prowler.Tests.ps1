#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\shared\EntityStore.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-Prowler.ps1')
}

Describe 'Normalize-Prowler' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\prowler-output.json') -Raw | ConvertFrom-Json
        $failedFixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\failed-output.json') -Raw | ConvertFrom-Json
    }

    Context 'v3 schema conversion' {
        BeforeAll {
            $results = Normalize-Prowler -ToolResult $fixture
        }

        It 'returns the correct number of findings' {
            @($results).Count | Should -Be 2
        }

        It 'sets Source, Platform, EntityType and SchemaVersion' {
            foreach ($r in $results) {
                $r.Source | Should -Be 'prowler'
                $r.Platform | Should -Be 'Azure'
                $r.EntityType | Should -Be 'AzureResource'
                $r.SchemaVersion | Should -Be '2.2'
            }
        }
    }

    Context 'Schema 2.2 fields are emitted' {
        BeforeAll {
            $results = Normalize-Prowler -ToolResult $fixture
        }

        It 'sets Security pillar and tool version' {
            $results[0].Pillar | Should -Be 'Security'
            $results[0].ToolVersion | Should -Be '4.8.1'
        }

        It 'emits flattened framework tuples for merge helper compatibility' {
            @($results[0].Frameworks | Where-Object { $_.kind -eq 'CIS' -and $_.controlId -eq 'azure_storage_secure_transfer_required' }).Count | Should -Be 1
            @($results[0].Frameworks | Where-Object { $_.kind -eq 'NIST' -and $_.controlId -eq 'azure_storage_secure_transfer_required' }).Count | Should -Be 1
            @($results[0].Frameworks | Where-Object { $_.kind -eq 'PCI-DSS' -and $_.controlId -eq 'azure_storage_secure_transfer_required' }).Count | Should -Be 1
        }

        It 'preserves baseline tags, mitigation data, snippets and links' {
            $results[0].BaselineTags | Should -Contain 'baseline:cis'
            $results[0].MitreTactics | Should -Contain 'Defense Evasion'
            $results[0].MitreTechniques | Should -Contain 'T1562'
            @($results[0].RemediationSnippets).Count | Should -BeGreaterThan 0
            $results[0].DeepLinkUrl | Should -Match 'docs\.prowler\.com'
        }

        It 'maps EvidenceUris from ResourceArn' {
            $results[0].EvidenceUris | Should -Contain 'arn:azure:storage:stprod01'
        }
    }

    Context 'canonical ARM entity identity' {
        BeforeAll {
            $results = Normalize-Prowler -ToolResult $fixture
        }

        It 'uses lowercased ARM EntityId to deduplicate with other tools' {
            foreach ($r in $results) {
                $r.EntityId | Should -BeExactly $r.EntityId.ToLowerInvariant()
                $r.EntityId | Should -Match '^/subscriptions/'
            }
        }
    }

    Context 'framework union contract' {
        BeforeAll {
            $results = Normalize-Prowler -ToolResult $fixture
        }

        It 'supports dedupe with Merge-FrameworksUnion for overlapping framework tuples' {
            $merged = Merge-FrameworksUnion -Existing $results[0].Frameworks -Incoming $results[0].Frameworks
            @($merged).Count | Should -Be @($results[0].Frameworks).Count
        }
    }

    Context 'error handling' {
        It 'returns empty array for failed output' {
            $results = Normalize-Prowler -ToolResult $failedFixture
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for null Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'prowler'; Status = 'Success'; Findings = $null }
            $results = Normalize-Prowler -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }
    }
}
