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

        It 'sets Platform to ADO' {
            foreach ($r in $results) {
                $r.Platform | Should -Be 'ADO'
            }
        }

        It 'maps ADO assets to the expected entity types' {
            @($results.EntityType | Select-Object -Unique) | Should -Contain 'Pipeline'
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

        It 'uses ado:// canonical IDs for every finding' {
            foreach ($r in $results) {
                $r.EntityId | Should -Match '^ado://'
            }
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
}
