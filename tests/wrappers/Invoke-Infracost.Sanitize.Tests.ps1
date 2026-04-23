#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-Infracost.ps1'
}

Describe 'Invoke-Infracost: SEC-001 sanitize raw JSON output before write' {
    Context 'when CLI returns JSON containing a secret-shaped string' {
        BeforeAll {
            $scanPath = Join-Path $TestDrive 'iac-sanitize'
            New-Item -ItemType Directory -Path $scanPath -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $scanPath 'main.tf') -Value 'resource "azurerm_resource_group" "rg" {}' -Encoding utf8

            # Fake secret long enough to trigger Remove-Credentials OpenAI rule (sk-...{20,})
            $script:FakeSecret = 'sk-test-FAKE-DEADBEEFCAFEBABE12345'

            $global:InfracostBreakdownJson = @"
{
  "apiKey": "$($script:FakeSecret)",
  "projects": [
    {
      "name": "terraform-main",
      "path": "infra/terraform",
      "breakdown": {
        "totalMonthlyCost": "10.00",
        "totalHourlyCost": "0.014",
        "resources": [
          {
            "name": "azurerm_resource_group.rg",
            "resourceType": "azurerm_resource_group",
            "monthlyCost": "10.00",
            "currency": "USD"
          }
        ]
      }
    }
  ]
}
"@

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
                    return [PSCustomObject]@{ ExitCode = 0; Output = "Infracost v0.10.31`n" }
                }
                return [PSCustomObject]@{ ExitCode = 0; Output = $global:InfracostBreakdownJson }
            }

            $script:result = & $script:Wrapper -Path $scanPath
            $script:breakdownPath = Join-Path $scanPath 'infracost-breakdown.json'
        }

        AfterAll {
            Remove-Item function:\global:Invoke-WithRetry -ErrorAction SilentlyContinue
            Remove-Item function:\global:Invoke-WithTimeout -ErrorAction SilentlyContinue
            Remove-Variable -Name InfracostBreakdownJson -Scope Global -ErrorAction SilentlyContinue
        }

        It 'wrote the breakdown JSON to disk' {
            Test-Path $script:breakdownPath | Should -BeTrue
        }

        It 'does NOT contain the raw fake secret on disk' {
            $contents = Get-Content -LiteralPath $script:breakdownPath -Raw
            $contents | Should -Not -Match ([regex]::Escape($script:FakeSecret))
        }

        It 'replaced the secret with the OpenAI redaction marker' {
            $contents = Get-Content -LiteralPath $script:breakdownPath -Raw
            $contents | Should -Match '\[OPENAI-KEY-REDACTED\]'
        }

        It 'still produced a Success v1 envelope' {
            $script:result.Status | Should -Be 'Success'
            $script:result.SchemaVersion | Should -Be '1.0'
        }
    }
}
