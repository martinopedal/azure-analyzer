#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Guarantee Class A tool-missing warnings stay suppressed when this file runs
# in isolation (single-file Invoke-Pester). The full-suite bootstrap sets the
# same flag via tests/_Bootstrap.Tests.ps1; this is the belt-and-suspenders
# equivalent for isolated / CI shard runs. See tests/_helpers/Suppress-WrapperWarnings.ps1.
$env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS = if ($null -eq $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS) { '__unset__' } else { $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS }
$env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = '1'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-AlzQueries.ps1'
}

Describe 'Invoke-AlzQueries: error paths' {
    Context 'when Az.ResourceGraph module is missing' {
        BeforeAll {
            Mock Get-Module { return $null }
            $result = & $script:Wrapper -ManagementGroupId 'mg-test'
        }

        It 'returns Status = Skipped' {
            $result.Status | Should -Be 'Skipped'
        }

        It 'returns empty Findings' {
            @($result.Findings).Count | Should -Be 0
        }

        It 'includes message about module not installed' {
            $result.Message | Should -Match 'not installed'
        }

        It 'sets Source to alz-queries' {
            $result.Source | Should -Be 'alz-queries'
        }

        It 'includes SchemaVersion 1.0 in the v1 envelope' {
            $result.SchemaVersion | Should -Be '1.0'
        }
    }
}

Describe 'Invoke-AlzQueries: success path metadata' {
    BeforeAll {
        $queriesFile = Join-Path $TestDrive 'alz_additional_queries.json'
        @'
{
  "metadata": { "version": "1.2.3" },
  "queries": [
    {
      "guid": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      "category": "Identity and Access Management",
      "subcategory": "Identity",
      "severity": "High",
      "text": "Sample ALZ query",
      "queryable": true,
      "queryIntent": "findViolations",
      "description": "Sample query description",
      "graph": "Resources | project id, compliant=0"
    }
  ]
}
'@ | Set-Content -Path $queriesFile -Encoding utf8

        Mock Get-Module {
            [PSCustomObject]@{ Name = 'Az.ResourceGraph' }
        }
        Mock Import-Module { }
        Mock Search-AzGraph {
            @([PSCustomObject]@{
                    id = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-test/providers/Microsoft.KeyVault/vaults/kv-test'
                    compliant = 0
                })
        }

        $result = & $script:Wrapper -ManagementGroupId 'mg-test' -QueriesFile $queriesFile
    }

    It 'returns success with metadata-derived tool version' {
        $result.Status | Should -Be 'Success'
        $result.ToolVersion | Should -Be '1.2.3'
    }

    It 'emits query metadata fields on findings' {
        @($result.Findings).Count | Should -Be 1
        $result.Findings[0].Subcategory | Should -Be 'Identity'
        $result.Findings[0].QueryIntent | Should -Be 'findViolations'
        $result.Findings[0].Description | Should -Be 'Sample query description'
        $result.Findings[0].ToolVersion | Should -Be '1.2.3'
        $result.Findings[0].QuerySource | Should -Match 'alz-graph-queries'
    }
}

AfterAll {
    if ($env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS -eq '__unset__') {
        Remove-Item Env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS -ErrorAction SilentlyContinue
    } elseif ($null -ne $env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS) {
        $env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = $env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS
    }
    Remove-Item Env:AZURE_ANALYZER_TEST_PRIOR_SUPPRESS -ErrorAction SilentlyContinue
}
