#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# E2E wrapper coverage for terraform-iac (#665). Drives the IaC adapter
# (which is what Invoke-IaCTerraform.ps1 delegates to) through mocked
# Invoke-WithTimeout calls for both `terraform validate` and `trivy config`,
# then runs the v1 envelope through the v2 normalizer and asserts FindingRow
# shape. The wrapper script's error paths are already covered by
# Invoke-IaCTerraform.Tests.ps1; this file extends coverage to the success
# path and the wrapper -> normalizer hand-off.
$env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = '1'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = (Resolve-Path (Join-Path $script:Here '..' '..')).Path

    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Sanitize.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Retry.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Canonicalize.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Schema.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'iac' 'IaCAdapters.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'normalizers' 'Normalize-IaCTerraform.ps1')

    $script:FixtureDir       = Join-Path $script:RepoRoot 'tests' 'fixtures' 'iac'
    $script:TerraformFixture = Join-Path $script:FixtureDir 'main.tf'
    $script:ValidateJson     = Get-Content -Path (Join-Path $script:FixtureDir 'terraform-validate.json') -Raw
    $script:TrivyJson        = Get-Content -Path (Join-Path $script:FixtureDir 'trivy-config.json') -Raw
}

Describe 'Invoke-IaCTerraform: E2E wrapper -> normalizer (#665)' {

    BeforeAll {
        $script:RepoFixture = Join-Path $TestDrive 'tf-repo'
        New-Item -ItemType Directory -Path $script:RepoFixture -Force | Out-Null
        Copy-Item -Path $script:TerraformFixture -Destination (Join-Path $script:RepoFixture 'main.tf') -Force
    }

    Context 'when terraform validate and trivy config emit findings' {

        BeforeAll {
            Mock Get-Command { return @{ Name = 'terraform' } } -ParameterFilter { $Name -eq 'terraform' }
            Mock Get-Command { return @{ Name = 'trivy' } }     -ParameterFilter { $Name -eq 'trivy' }

            Mock Invoke-WithTimeout {
                $TimeoutSec | Should -BeIn @(60, 300)

                if ($Command -eq 'terraform' -and ($Arguments -contains 'init')) {
                    return [PSCustomObject]@{ ExitCode = 0; Output = 'Terraform has been successfully initialized!' }
                }
                if ($Command -eq 'terraform' -and ($Arguments -contains 'validate')) {
                    return [PSCustomObject]@{ ExitCode = 1; Output = $script:ValidateJson }
                }
                if ($Command -eq 'terraform' -and ($Arguments -contains 'version')) {
                    return [PSCustomObject]@{ ExitCode = 0; Output = 'Terraform v1.7.5' }
                }
                if ($Command -eq 'trivy' -and ($Arguments -contains '--version')) {
                    return [PSCustomObject]@{ ExitCode = 0; Output = 'Version: 0.50.1' }
                }
                if ($Command -eq 'trivy' -and ($Arguments -contains 'config')) {
                    $outIdx = [array]::IndexOf($Arguments, '--output')
                    if ($outIdx -ge 0 -and $outIdx + 1 -lt $Arguments.Count) {
                        Set-Content -Path $Arguments[$outIdx + 1] -Value $script:TrivyJson -Encoding utf8
                    }
                    return [PSCustomObject]@{ ExitCode = 0; Output = '' }
                }
                return [PSCustomObject]@{ ExitCode = 0; Output = '' }
            }

            $script:Result = Invoke-TerraformValidation -RepoPath $script:RepoFixture
        }

        It 'returns a v1 envelope with Source = terraform-iac and SchemaVersion 1.0' {
            $script:Result.Source        | Should -Be 'terraform-iac'
            $script:Result.SchemaVersion | Should -Be '1.0'
            $script:Result.Status        | Should -Be 'Success'
        }

        It 'enforces the 300s timeout invariant via Invoke-WithTimeout' {
            Should -Invoke Invoke-WithTimeout -Scope Context -Times 2
        }

        It 'emits at least one terraform-validate finding' {
            @($script:Result.Findings | Where-Object { $_.RuleId -eq 'terraform-validate' }).Count | Should -BeGreaterThan 0
        }

        It 'emits at least one trivy AVD finding' {
            @($script:Result.Findings | Where-Object { $_.Detail -match 'TLS|tls' -or $_.Title -match 'TLS' }).Count | Should -BeGreaterThan 0
        }

        It 'records the captured tool versions in ToolVersion' {
            $script:Result.ToolVersion | Should -Match 'Terraform v1.7.5'
            $script:Result.ToolVersion | Should -Match '0\.50\.1'
        }
    }

    Context 'when the v1 envelope is fed to Normalize-IaCTerraform' {

        BeforeAll {
            Mock Get-Command { return @{ Name = 'terraform' } } -ParameterFilter { $Name -eq 'terraform' }
            Mock Get-Command { return @{ Name = 'trivy' } }     -ParameterFilter { $Name -eq 'trivy' }

            Mock Invoke-WithTimeout {
                if ($Command -eq 'terraform' -and ($Arguments -contains 'init')) {
                    return [PSCustomObject]@{ ExitCode = 0; Output = '' }
                }
                if ($Command -eq 'terraform' -and ($Arguments -contains 'validate')) {
                    return [PSCustomObject]@{ ExitCode = 1; Output = $script:ValidateJson }
                }
                if ($Command -eq 'terraform' -and ($Arguments -contains 'version')) {
                    return [PSCustomObject]@{ ExitCode = 0; Output = 'Terraform v1.7.5' }
                }
                if ($Command -eq 'trivy' -and ($Arguments -contains '--version')) {
                    return [PSCustomObject]@{ ExitCode = 0; Output = 'Version: 0.50.1' }
                }
                if ($Command -eq 'trivy' -and ($Arguments -contains 'config')) {
                    $outIdx = [array]::IndexOf($Arguments, '--output')
                    if ($outIdx -ge 0 -and $outIdx + 1 -lt $Arguments.Count) {
                        Set-Content -Path $Arguments[$outIdx + 1] -Value $script:TrivyJson -Encoding utf8
                    }
                    return [PSCustomObject]@{ ExitCode = 0; Output = '' }
                }
                return [PSCustomObject]@{ ExitCode = 0; Output = '' }
            }

            $envelope = Invoke-TerraformValidation -RepoPath $script:RepoFixture -SourceRepoUrl 'https://github.com/contoso/iac'
            $script:Rows = @(Normalize-IaCTerraform -ToolResult $envelope)
        }

        It 'produces at least one v2 FindingRow' {
            @($script:Rows).Count | Should -BeGreaterThan 0
        }

        It 'every row reports SchemaVersion 2.2 (v2 FindingRow)' {
            foreach ($r in $script:Rows) { $r.SchemaVersion | Should -Be '2.2' }
        }

        It 'every row uses Source = terraform-iac and EntityType = Repository' {
            foreach ($r in $script:Rows) {
                $r.Source     | Should -Be 'terraform-iac'
                $r.EntityType | Should -Be 'Repository'
            }
        }

        It 'maps trivy HIGH severity into the canonical 5-level enum' {
            $severities = @($script:Rows | ForEach-Object { $_.Severity })
            $severities | Should -Contain 'High'
        }

        It 'populates v2 enrichment fields (RuleId, Pillar, EvidenceUris)' {
            foreach ($r in $script:Rows) {
                $r.RuleId | Should -Not -BeNullOrEmpty
                $r.Pillar | Should -Not -BeNullOrEmpty
                @($r.EvidenceUris).Count | Should -BeGreaterThan 0
            }
        }

        It 'sets Provenance.RunId consistently across the run' {
            $runIds = $script:Rows | ForEach-Object { $_.Provenance.RunId } | Select-Object -Unique
            @($runIds).Count | Should -Be 1
        }
    }
}
