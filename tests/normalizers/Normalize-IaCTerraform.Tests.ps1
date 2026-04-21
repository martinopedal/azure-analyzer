#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-IaCTerraform.ps1')
}

Describe 'Normalize-IaCTerraform' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\iac-terraform-output.json') -Raw | ConvertFrom-Json
        $failedFixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\failed-output.json') -Raw | ConvertFrom-Json
    }

    Context 'v3 schema conversion' {
        BeforeAll {
            $results = Normalize-IaCTerraform -ToolResult $fixture
        }

        It 'returns the correct number of findings' {
            @($results).Count | Should -Be 5
        }

        It 'sets SchemaVersion to 2.0' {
            foreach ($r in $results) {
                $r.SchemaVersion | Should -Be '2.2'
            }
        }

        It 'sets Source to terraform-iac' {
            foreach ($r in $results) {
                $r.Source | Should -Be 'terraform-iac'
            }
        }

        It 'sets Platform to GitHub' {
            foreach ($r in $results) {
                $r.Platform | Should -Be 'GitHub'
            }
        }

        It 'sets EntityType to Repository' {
            foreach ($r in $results) {
                $r.EntityType | Should -Be 'Repository'
            }
        }
    }

    Context 'EntityId normalization' {
        BeforeAll {
            $results = Normalize-IaCTerraform -ToolResult $fixture
        }

        It 'uses iac.local/terraform-iac prefix for EntityId' {
            foreach ($r in $results) {
                $r.EntityId | Should -Match '^iac\.local/terraform-iac/'
            }
        }

        It 'has a non-empty EntityId for all findings' {
            foreach ($r in $results) {
                $r.EntityId | Should -Not -BeNullOrEmpty
            }
        }

        It 'normalizes directory paths to lowercase' {
            $results[0].EntityId | Should -BeExactly 'iac.local/terraform-iac/infra'
        }
    }

    Context 'category preservation' {
        BeforeAll {
            $results = Normalize-IaCTerraform -ToolResult $fixture
        }

        It 'preserves IaC Validation category for validate findings' {
            ($results | Where-Object { $_.Category -eq 'IaC Validation' }).Count | Should -BeGreaterThan 0
        }

        It 'preserves IaC Security category for trivy config findings' {
            ($results | Where-Object { $_.Category -eq 'IaC Security' }).Count | Should -BeGreaterThan 0
        }
    }

    Context 'severity mapping covers all five levels' {
        BeforeAll {
            $results = Normalize-IaCTerraform -ToolResult $fixture
        }

        It 'maps Critical severity' {
            ($results | Where-Object { $_.Severity -eq 'Critical' }).Count | Should -BeGreaterThan 0
        }

        It 'maps High severity' {
            ($results | Where-Object { $_.Severity -eq 'High' }).Count | Should -BeGreaterThan 0
        }

        It 'maps Medium severity' {
            ($results | Where-Object { $_.Severity -eq 'Medium' }).Count | Should -BeGreaterThan 0
        }

        It 'maps Low severity' {
            ($results | Where-Object { $_.Severity -eq 'Low' }).Count | Should -BeGreaterThan 0
        }

        It 'maps Info severity' {
            ($results | Where-Object { $_.Severity -eq 'Info' }).Count | Should -BeGreaterThan 0
        }
    }

    Context 'field preservation' {
        BeforeAll {
            $results = Normalize-IaCTerraform -ToolResult $fixture
        }

        It 'preserves Compliant boolean (all false for errors)' {
            foreach ($r in $results) {
                $r.Compliant | Should -BeFalse
            }
        }

        It 'preserves Title for validate finding' {
            $results[0].Title | Should -Match 'Terraform validate'
        }

        It 'preserves Title for trivy config finding' {
            $results[1].Title | Should -Match 'AVD-AZU'
        }

        It 'preserves Detail' {
            $results[0].Detail | Should -Not -BeNullOrEmpty
        }

        It 'preserves Remediation' {
            $results[0].Remediation | Should -Not -BeNullOrEmpty
        }

        It 'preserves LearnMoreUrl' {
            $results[0].LearnMoreUrl | Should -Match 'hashicorp\.com|aquasec\.com'
        }
    }

    Context 'Provenance tracking' {
        BeforeAll {
            $results = Normalize-IaCTerraform -ToolResult $fixture
        }

        It 'sets Provenance with RunId' {
            foreach ($r in $results) {
                $r.Provenance | Should -Not -BeNullOrEmpty
                $r.Provenance.RunId | Should -Not -BeNullOrEmpty
            }
        }

        It 'uses consistent RunId across all findings' {
            $runIds = $results | ForEach-Object { $_.Provenance.RunId } | Select-Object -Unique
            @($runIds).Count | Should -Be 1
        }
    }

    Context 'error handling' {
        It 'returns empty array for failed tool output' {
            $results = Normalize-IaCTerraform -ToolResult $failedFixture
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for null Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'terraform-iac'; Status = 'Success'; Findings = $null }
            $results = Normalize-IaCTerraform -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }

        It 'returns empty array for empty Findings' {
            $emptyResult = [PSCustomObject]@{ Source = 'terraform-iac'; Status = 'Success'; Findings = @() }
            $results = Normalize-IaCTerraform -ToolResult $emptyResult
            @($results).Count | Should -Be 0
        }

        It 'handles missing optional fields gracefully' {
            $minimalInput = [PSCustomObject]@{
                Source   = 'terraform-iac'
                Status   = 'Success'
                Findings = @(
                    [PSCustomObject]@{
                        ResourceId = 'infra'
                        Title      = 'TF validate error'
                        Compliant  = $false
                        Severity   = 'High'
                    }
                )
            }
            $results = Normalize-IaCTerraform -ToolResult $minimalInput
            @($results).Count | Should -Be 1
            $results[0].Source | Should -Be 'terraform-iac'
        }
    }

    Context 'no Azure subscription context' {
        BeforeAll {
            $results = Normalize-IaCTerraform -ToolResult $fixture
        }

        It 'does not set SubscriptionId' {
            foreach ($r in $results) {
                $r.SubscriptionId | Should -BeNullOrEmpty
            }
        }

        It 'does not set ResourceGroup' {
            foreach ($r in $results) {
                $r.ResourceGroup | Should -BeNullOrEmpty
            }
        }
    }
}
