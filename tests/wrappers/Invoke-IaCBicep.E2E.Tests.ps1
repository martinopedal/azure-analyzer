#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# E2E wrapper coverage for bicep-iac (#663). Drives the IaC adapter
# (which is what Invoke-IaCBicep.ps1 delegates to) through a mocked
# Invoke-WithTimeout, then runs the v1 envelope through the v2 normalizer
# and asserts FindingRow shape. The wrapper script's error paths are
# already covered by Invoke-IaCBicep.Tests.ps1; this file extends coverage
# to the success path and the wrapper -> normalizer hand-off.
$env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = '1'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = (Resolve-Path (Join-Path $script:Here '..' '..')).Path

    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Sanitize.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Retry.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Canonicalize.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Schema.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'iac' 'IaCAdapters.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'normalizers' 'Normalize-IaCBicep.ps1')

    $script:FixtureDir = Join-Path $script:RepoRoot 'tests' 'fixtures' 'iac'
    $script:BicepFixture = Join-Path $script:FixtureDir 'main.bicep'
    $script:BicepOutput  = Get-Content -Path (Join-Path $script:FixtureDir 'bicep-build-output.txt') -Raw
}

Describe 'Invoke-IaCBicep: E2E wrapper -> normalizer (#663)' {

    BeforeAll {
        $script:RepoFixture = Join-Path $TestDrive 'bicep-repo'
        New-Item -ItemType Directory -Path $script:RepoFixture -Force | Out-Null
        Copy-Item -Path $script:BicepFixture -Destination (Join-Path $script:RepoFixture 'main.bicep') -Force
    }

    Context 'when bicep build emits diagnostics' {

        BeforeAll {
            Mock Get-Command { return @{ Name = 'bicep' } } -ParameterFilter { $Name -eq 'bicep' }
            Mock Invoke-WithTimeout {
                $TimeoutSec | Should -Be 300
                $Command    | Should -Be 'bicep'
                $Arguments  | Should -Contain 'build'
                return [PSCustomObject]@{ ExitCode = 1; Output = $script:BicepOutput }
            }

            $script:Result = Invoke-BicepValidation -RepoPath $script:RepoFixture
        }

        It 'returns a v1 envelope with Source = bicep-iac and SchemaVersion 1.0' {
            $script:Result.Source        | Should -Be 'bicep-iac'
            $script:Result.SchemaVersion | Should -Be '1.0'
            $script:Result.Status        | Should -Be 'Success'
        }

        It 'enforces the 300s timeout invariant via Invoke-WithTimeout' {
            Should -Invoke Invoke-WithTimeout -Times 1 -Exactly -Scope Context
        }

        It 'emits one finding per bicep diagnostic line' {
            @($script:Result.Findings).Count | Should -Be 2
        }

        It 'parses BCP062 and BCP036 rule ids from the diagnostic stream' {
            $ruleIds = @($script:Result.Findings | ForEach-Object { $_.RuleId })
            $ruleIds | Should -Contain 'BCP062'
            $ruleIds | Should -Contain 'BCP036'
        }

        It 'marks every diagnostic as non-compliant' {
            foreach ($f in $script:Result.Findings) { $f.Compliant | Should -BeFalse }
        }
    }

    Context 'when the v1 envelope is fed to Normalize-IaCBicep' {

        BeforeAll {
            Mock Get-Command { return @{ Name = 'bicep' } } -ParameterFilter { $Name -eq 'bicep' }
            Mock Invoke-WithTimeout {
                return [PSCustomObject]@{ ExitCode = 1; Output = $script:BicepOutput }
            }

            $envelope = Invoke-BicepValidation -RepoPath $script:RepoFixture
            $envelope | Add-Member -NotePropertyName ToolVersion -NotePropertyValue 'bicep:0.31.92' -Force
            $script:Rows = @(Normalize-IaCBicep -ToolResult $envelope)
        }

        It 'produces one v2 FindingRow per v1 finding' {
            @($script:Rows).Count | Should -Be 2
        }

        It 'every row reports SchemaVersion 2.2 (v2 FindingRow)' {
            foreach ($r in $script:Rows) { $r.SchemaVersion | Should -Be '2.2' }
        }

        It 'every row uses Source = bicep-iac and EntityType = AzureResource' {
            foreach ($r in $script:Rows) {
                $r.Source     | Should -Be 'bicep-iac'
                $r.EntityType | Should -Be 'AzureResource'
                $r.Platform   | Should -Be 'Azure'
            }
        }

        It 'maps Bicep severities into the canonical 5-level enum' {
            $severities = @($script:Rows | ForEach-Object { $_.Severity })
            $severities | Should -Contain 'High'
            $severities | Should -Contain 'Medium'
        }

        It 'canonicalises EntityId into a synthetic ARM deployment id' {
            foreach ($r in $script:Rows) {
                $r.EntityId | Should -Match '^/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/iac-bicep/providers/microsoft\.resources/deployments/'
            }
        }

        It 'populates v2 enrichment fields (RuleId, Pillar, Frameworks, EvidenceUris, ToolVersion)' {
            foreach ($r in $script:Rows) {
                $r.RuleId      | Should -Not -BeNullOrEmpty
                $r.Pillar      | Should -Not -BeNullOrEmpty
                $r.DeepLinkUrl | Should -Not -BeNullOrEmpty
                @($r.Frameworks).Count   | Should -BeGreaterThan 0
                @($r.EvidenceUris).Count | Should -BeGreaterThan 0
                $r.ToolVersion | Should -Match 'bicep'
            }
        }

        It 'sets Provenance.RunId consistently across the run' {
            $runIds = $script:Rows | ForEach-Object { $_.Provenance.RunId } | Select-Object -Unique
            @($runIds).Count | Should -Be 1
        }
    }
}
