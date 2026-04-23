#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# See tests/wrappers/Invoke-AlzQueries.Tests.ps1 header -- single-file run guard.
$env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = '1'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-Infracost.ps1'
}

Describe 'Invoke-Infracost: error paths' {
    Context 'when infracost CLI is missing' {
        BeforeAll {
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'infracost' }
            $result = & $script:Wrapper
        }

        It 'returns Status = Skipped' {
            $result.Status | Should -Be 'Skipped'
        }

        It 'returns Source = infracost' {
            $result.Source | Should -Be 'infracost'
        }

        It 'returns SchemaVersion 1.0' {
            $result.SchemaVersion | Should -Be '1.0'
        }
    }

    Context 'when scan path does not exist' {
        BeforeAll {
            Mock Get-Command { return @{ Name = 'infracost' } } -ParameterFilter { $Name -eq 'infracost' }
            $result = & $script:Wrapper -Path 'C:\does-not-exist\infracost'
        }

        It 'returns Status = Failed' {
            $result.Status | Should -Be 'Failed'
        }
    }
}

Describe 'Invoke-Infracost: success path' {
    Context 'when infracost returns JSON breakdown output' {
        BeforeAll {
            $scanPath = Join-Path $TestDrive 'iac'
            New-Item -ItemType Directory -Path $scanPath -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $scanPath 'main.tf') -Value 'resource "azurerm_resource_group" "rg" {}' -Encoding utf8

            $global:InfracostBreakdownJson = @'
{
  "projects": [
    {
      "name": "terraform-main",
      "path": "infra/terraform",
      "cloudUrl": "https://app.infracost.io/orgs/contoso/projects/terraform-main",
      "breakdown": {
        "totalMonthlyCost": "1453.25",
        "totalHourlyCost": "1.9908",
        "resources": [
          {
            "name": "azurerm_kubernetes_cluster.aks",
            "resourceType": "azurerm_kubernetes_cluster",
            "monthlyCost": "1260.75",
            "currency": "USD"
          }
        ]
      },
      "pastBreakdown": {
        "totalMonthlyCost": "1410.75"
      },
      "diff": {
        "totalMonthlyCost": "42.50"
      }
    }
  ]
}
'@
            Mock Get-Command { return @{ Name = 'infracost' } } -ParameterFilter { $Name -eq 'infracost' }

            function global:Invoke-WithRetry {
                param(
                    [scriptblock]$ScriptBlock,
                    [int]$MaxAttempts,
                    [int]$InitialDelaySeconds,
                    [int]$MaxDelaySeconds
                )
                & $ScriptBlock
            }

            function global:Invoke-WithTimeout {
                param(
                    [string]$Command,
                    [string[]]$Arguments,
                    [int]$TimeoutSec
                )
                if ($Arguments -contains '--version') {
                    if ($TimeoutSec -ne 300) { throw "Infracost --version called with TimeoutSec=$TimeoutSec; expected 300" }
                    return [PSCustomObject]@{
                        ExitCode = 0
                        Output   = "Infracost v0.10.31`n"
                    }
                }
                if ($TimeoutSec -ne 300) { throw "Infracost breakdown called with TimeoutSec=$TimeoutSec; expected 300" }
                return [PSCustomObject]@{
                    ExitCode = 0
                    Output   = $global:InfracostBreakdownJson
                }
            }

            $result = & $script:Wrapper -Path $scanPath
        }

        AfterAll {
            Remove-Item function:\global:Invoke-WithRetry -ErrorAction SilentlyContinue
            Remove-Item function:\global:Invoke-WithTimeout -ErrorAction SilentlyContinue
            Remove-Variable -Name InfracostBreakdownJson -Scope Global -ErrorAction SilentlyContinue
        }

        It 'returns Success with ToolSummary in v1 envelope' {
            $result.Status | Should -Be 'Success'
            $result.SchemaVersion | Should -Be '1.0'
            $result.ToolSummary | Should -Not -BeNullOrEmpty
            $result.ToolSummary.Currency | Should -Be 'USD'
            $result.ToolSummary.TotalMonthlyCost | Should -Be 1453.25
            $result.ToolSummary.BaselineMonthlyCost | Should -Be 1410.75
            $result.ToolSummary.DiffMonthlyCost | Should -Be 42.5
        }

        It 'emits schema 2.2 ETL source fields on findings' {
            $result.Findings.Count | Should -Be 1
            $finding = $result.Findings[0]
            $finding.Pillar | Should -Be 'Cost'
            $finding.ToolVersion | Should -Be 'Infracost v0.10.31'
            $finding.Effort | Should -Be 'Medium'
            $finding.EntityRefs | Should -Contain 'infra/terraform'
            $finding.EvidenceUris.Count | Should -BeGreaterThan 0
            $finding.RemediationSnippets.Count | Should -BeGreaterThan 0
            $finding.DiffMonthlyCost | Should -Be 42.5
        }
    }
}
