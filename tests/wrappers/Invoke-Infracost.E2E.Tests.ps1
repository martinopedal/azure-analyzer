#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# E2E wrapper coverage for infracost (#664). Invokes the wrapper script
# end-to-end with realistic fixture output, then runs the v1 envelope
# through Normalize-Infracost and asserts FindingRow shape. The wrapper's
# error paths plus a thinner inline success path are already covered by
# Invoke-Infracost.Tests.ps1; this file extends coverage to the wrapper
# -> normalizer hand-off using the shared tests/fixtures/iac fixture.
$env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = '1'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = (Resolve-Path (Join-Path $script:Here '..' '..')).Path
    $script:Wrapper  = Join-Path $script:RepoRoot 'modules' 'Invoke-Infracost.ps1'

    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Sanitize.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Canonicalize.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Schema.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'normalizers' 'Normalize-Infracost.ps1')

    $script:FixtureDir   = Join-Path $script:RepoRoot 'tests' 'fixtures' 'iac'
    $script:Breakdown    = Get-Content -Path (Join-Path $script:FixtureDir 'infracost-breakdown.json') -Raw
    $script:TerraformSrc = Get-Content -Path (Join-Path $script:FixtureDir 'main.tf') -Raw
}

Describe 'Invoke-Infracost: E2E wrapper -> normalizer (#664)' {

    BeforeAll {
        $script:ScanPath = Join-Path $TestDrive 'infracost-iac'
        New-Item -ItemType Directory -Path $script:ScanPath -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:ScanPath 'main.tf') -Value $script:TerraformSrc -Encoding utf8
    }

    Context 'when infracost returns a JSON breakdown' {

        BeforeAll {
            $global:InfracostBreakdownE2EJson = $script:Breakdown

            Mock Get-Command { return @{ Name = 'infracost' } } -ParameterFilter { $Name -eq 'infracost' }

            function global:Invoke-WithRetry {
                param (
                    [scriptblock] $ScriptBlock,
                    [int] $MaxAttempts,
                    [int] $InitialDelaySeconds,
                    [int] $MaxDelaySeconds
                )
                & $ScriptBlock
            }

            function global:Invoke-WithTimeout {
                param (
                    [string]   $Command,
                    [string[]] $Arguments,
                    [int]      $TimeoutSec
                )
                # 300s timeout invariant for breakdown calls; 60s allowed for --version probe
                if ($Arguments -contains '--version') {
                    if ($TimeoutSec -lt 60) { throw "Infracost --version called with TimeoutSec=$TimeoutSec; expected >= 60" }
                    return [PSCustomObject]@{ ExitCode = 0; Output = "Infracost v0.10.31`n" }
                }
                if ($TimeoutSec -ne 300) { throw "Infracost breakdown called with TimeoutSec=$TimeoutSec; expected 300" }
                return [PSCustomObject]@{ ExitCode = 0; Output = $global:InfracostBreakdownE2EJson }
            }

            $script:Result = & $script:Wrapper -Path $script:ScanPath
        }

        AfterAll {
            Remove-Item Function:\global:Invoke-WithRetry  -ErrorAction SilentlyContinue
            Remove-Item Function:\global:Invoke-WithTimeout -ErrorAction SilentlyContinue
            Remove-Variable -Name InfracostBreakdownE2EJson -Scope Global -ErrorAction SilentlyContinue
        }

        It 'returns a v1 envelope with Source = infracost and SchemaVersion 1.0' {
            $script:Result.Source        | Should -Be 'infracost'
            $script:Result.SchemaVersion | Should -Be '1.0'
            $script:Result.Status        | Should -Be 'Success'
        }

        It 'parses ToolSummary totals from the breakdown JSON' {
            $script:Result.ToolSummary.Currency            | Should -Be 'USD'
            $script:Result.ToolSummary.TotalMonthlyCost    | Should -Be 874.20
            $script:Result.ToolSummary.BaselineMonthlyCost | Should -Be 612.50
            $script:Result.ToolSummary.DiffMonthlyCost     | Should -Be 261.70
        }

        It 'emits at least one finding per project breakdown' {
            @($script:Result.Findings).Count | Should -BeGreaterThan 0
            $script:Result.Findings[0].Pillar | Should -Be 'Cost'
        }
    }

    Context 'when the v1 envelope is fed to Normalize-Infracost' {

        BeforeAll {
            $global:InfracostBreakdownE2EJson = $script:Breakdown

            Mock Get-Command { return @{ Name = 'infracost' } } -ParameterFilter { $Name -eq 'infracost' }

            function global:Invoke-WithRetry {
                param (
                    [scriptblock] $ScriptBlock,
                    [int] $MaxAttempts,
                    [int] $InitialDelaySeconds,
                    [int] $MaxDelaySeconds
                )
                & $ScriptBlock
            }

            function global:Invoke-WithTimeout {
                param (
                    [string]   $Command,
                    [string[]] $Arguments,
                    [int]      $TimeoutSec
                )
                if ($Arguments -contains '--version') {
                    return [PSCustomObject]@{ ExitCode = 0; Output = 'Infracost v0.10.31' }
                }
                return [PSCustomObject]@{ ExitCode = 0; Output = $global:InfracostBreakdownE2EJson }
            }

            $envelope = & $script:Wrapper -Path $script:ScanPath
            $script:Rows = @(Normalize-Infracost -ToolResult $envelope)
        }

        AfterAll {
            Remove-Item Function:\global:Invoke-WithRetry  -ErrorAction SilentlyContinue
            Remove-Item Function:\global:Invoke-WithTimeout -ErrorAction SilentlyContinue
            Remove-Variable -Name InfracostBreakdownE2EJson -Scope Global -ErrorAction SilentlyContinue
        }

        It 'produces at least one v2 FindingRow' {
            @($script:Rows).Count | Should -BeGreaterThan 0
        }

        It 'every row reports SchemaVersion 2.2 (v2 FindingRow)' {
            foreach ($r in $script:Rows) { $r.SchemaVersion | Should -Be '2.2' }
        }

        It 'every row uses Source = infracost and Pillar = Cost Optimization' {
            foreach ($r in $script:Rows) {
                $r.Source | Should -Be 'infracost'
                $r.Pillar | Should -Match '(?i)cost'
            }
        }

        It 'canonicalises EntityId via ConvertTo-CanonicalEntityId (lowercase ARM-shaped)' {
            foreach ($r in $script:Rows) {
                $r.EntityId | Should -Not -BeNullOrEmpty
                $r.EntityId | Should -Match '^/subscriptions/'
            }
        }

        It 'populates v2 enrichment fields (EvidenceUris, ToolVersion)' {
            foreach ($r in $script:Rows) {
                @($r.EvidenceUris).Count | Should -BeGreaterThan 0
                $r.ToolVersion | Should -Match 'Infracost'
            }
        }

        It 'sets Provenance.RunId consistently across the run' {
            $runIds = $script:Rows | ForEach-Object { $_.Provenance.RunId } | Select-Object -Unique
            @($runIds).Count | Should -Be 1
        }
    }
}
