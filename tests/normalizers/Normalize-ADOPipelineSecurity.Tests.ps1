#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-ADOPipelineSecurity.ps1')
}

Describe 'Normalize-ADOPipelineSecurity' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\ado-pipelines-output.json') -Raw | ConvertFrom-Json
        $failedFixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\failed-output.json') -Raw | ConvertFrom-Json
    }

    Context 'v3 schema conversion' {
        BeforeAll {
            $results = Normalize-ADOPipelineSecurity -ToolResult $fixture
        }

        It 'returns the correct number of findings' {
            @($results).Count | Should -Be 5
        }

        It 'sets Source to ado-pipelines' {
            foreach ($r in $results) {
                $r.Source | Should -Be 'ado-pipelines'
            }
        }

        It 'sets Platform to AzureDevOps' {
            foreach ($r in $results) {
                $r.Platform | Should -Be 'AzureDevOps'
            }
        }

        It 'maps ADO assets to the expected entity types' {
            @($results.EntityType | Select-Object -Unique) | Should -Contain 'BuildDefinition'
            @($results.EntityType | Select-Object -Unique) | Should -Contain 'ReleaseDefinition'
            @($results.EntityType | Select-Object -Unique) | Should -Contain 'VariableGroup'
            @($results.EntityType | Select-Object -Unique) | Should -Contain 'Environment'
            @($results.EntityType | Select-Object -Unique) | Should -Contain 'ServiceConnection'
        }
    }

    Context 'canonicalization and field preservation' {
        BeforeAll {
            $results = Normalize-ADOPipelineSecurity -ToolResult $fixture
        }

        It 'lowercases EntityId values' {
            foreach ($r in $results) {
                $r.EntityId | Should -BeExactly $r.EntityId.ToLowerInvariant()
            }
        }

        It 'preserves non-compliant severities' {
            ($results | Where-Object { $_.Severity -eq 'High' }).Count | Should -BeGreaterThan 0
            ($results | Where-Object { $_.Severity -eq 'Medium' }).Count | Should -Be 1
            ($results | Where-Object { $_.Severity -eq 'Low' }).Count | Should -Be 1
        }

        It 'uses AzureDevOps entity key format for every finding' {
            foreach ($r in $results) {
                $r.EntityId | Should -Match '^[^/]+/[^/]+/[^/]+/.+'
            }
        }
    }

    Context 'schema 2.2 enrichment' {
        BeforeAll {
            $results = Normalize-ADOPipelineSecurity -ToolResult $fixture
            $branch = $results | Where-Object { $_.RuleId -eq 'Branch-Unprotected' } | Select-Object -First 1
        }

        It 'sets Pillar and tool metadata' {
            $branch.Pillar | Should -Be 'Security'
            $branch.ToolVersion | Should -Be '1.0.0'
        }

        It 'emits baseline tags and cross-entity references' {
            @($branch.BaselineTags) | Should -Contain 'Asset-BuildDefinition'
            @($branch.BaselineTags) | Should -Contain 'Branch-Unprotected'
            @($branch.EntityRefs).Count | Should -BeGreaterThan 0
        }

        It 'carries deep links, evidence URIs, and remediation snippets' {
            $branch.DeepLinkUrl | Should -Match '_build/definition'
            @($branch.EvidenceUris | Where-Object { $_ -match '_apis/build/definitions' }).Count | Should -Be 1
            @($branch.RemediationSnippets).Count | Should -BeGreaterThan 0
            $branch.RemediationSnippets[0].language | Should -Be 'bash'
        }

        It 'does not emit Frameworks or MITRE arrays for ado-pipelines' {
            @($branch.Frameworks).Count | Should -Be 0
            @($branch.MitreTactics).Count | Should -Be 0
            @($branch.MitreTechniques).Count | Should -Be 0
        }
    }

    Context 'error handling' {
        It 'returns empty array for failed tool output' {
            $results = Normalize-ADOPipelineSecurity -ToolResult $failedFixture
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for empty Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'ado-pipelines'; Status = 'Success'; Findings = @() }
            $results = Normalize-ADOPipelineSecurity -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }
    }

    Context 'severity normalization (all 5 levels)' {
        It 'normalizes raw severity strings case-insensitively' {
            $sevInput = [PSCustomObject]@{
                Status = 'Success'
                Findings = @(
                    @('CRITICAL','High','medium','LOW','info') | ForEach-Object {
                        [PSCustomObject]@{
                            Id = [guid]::NewGuid().ToString()
                            Title = "Sev-$_ test"
                            Category = 'Test'
                            Severity = $_
                            Compliant = $false
                            Detail = ''
                            Remediation = ''
                            LearnMoreUrl = ''
                            AssetType = 'pipeline'
                            AdoOrg = 'org'; AdoProject = 'proj'; AssetName = "pipe-$_"
                            SchemaVersion = '1.0'
                        }
                    }
                )
            }
            $rows = @(Normalize-ADOPipelineSecurity -ToolResult $sevInput)
            $rows.Count | Should -Be 5
            ($rows | Where-Object { $_.Severity -eq 'Critical' }).Count | Should -Be 1
            ($rows | Where-Object { $_.Severity -eq 'High' }).Count | Should -Be 1
            ($rows | Where-Object { $_.Severity -eq 'Medium' }).Count | Should -Be 1
            ($rows | Where-Object { $_.Severity -eq 'Low' }).Count | Should -Be 1
            ($rows | Where-Object { $_.Severity -eq 'Info' }).Count | Should -Be 1
        }
    }
}
