#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\shared\EntityStore.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-IaCTerraform.ps1')
}

Describe 'Normalize-IaCTerraform' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\iac-terraform-output.json') -Raw | ConvertFrom-Json
        $failedFixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\failed-output.json') -Raw | ConvertFrom-Json
        $results = Normalize-IaCTerraform -ToolResult $fixture
    }

    It 'returns expected finding count' {
        @($results).Count | Should -Be 5
    }

    It 'emits SchemaVersion 2.2 and Source terraform-iac' {
        foreach ($r in $results) {
            $r.SchemaVersion | Should -Be '2.2'
            $r.Source | Should -Be 'terraform-iac'
        }
    }

    It 'maps terraform IaC findings to GitHub platform and Repository entities' {
        foreach ($r in $results) {
            $r.Platform | Should -Be 'GitHub'
            $r.EntityType | Should -Be 'Repository'
            $r.EntityId | Should -Match '^iac\.local/terraform-iac/'
        }
    }

    It 'covers all five severities with UNKNOWN mapped to Info' {
        ($results | Where-Object Severity -eq 'Critical').Count | Should -BeGreaterThan 0
        ($results | Where-Object Severity -eq 'High').Count | Should -BeGreaterThan 0
        ($results | Where-Object Severity -eq 'Medium').Count | Should -BeGreaterThan 0
        ($results | Where-Object Severity -eq 'Low').Count | Should -BeGreaterThan 0
        ($results | Where-Object Severity -eq 'Info').Count | Should -BeGreaterThan 0
    }

    It 'preserves Schema 2.2 ETL fields' {
        $security = $results | Where-Object RuleId -eq 'AVD-AZU-0001' | Select-Object -First 1
        $security.Pillar | Should -Be 'Security'
        @($security.Frameworks).Count | Should -BeGreaterThan 0
        $security.DeepLinkUrl | Should -Match 'avd\.aquasec\.com'
        @($security.RemediationSnippets).Count | Should -BeGreaterThan 0
        @($security.EvidenceUris).Count | Should -BeGreaterThan 0
        @($security.BaselineTags).Count | Should -BeGreaterThan 0
        @($security.EntityRefs).Count | Should -BeGreaterThan 0
        $security.ToolVersion | Should -Not -BeNullOrEmpty
    }

    It 'normalizes terraform validate pillar naming to canonical WAF string' {
        $validateFinding = $results | Where-Object RuleId -eq 'terraform-validate' | Select-Object -First 1
        $validateFinding.Pillar | Should -Be 'OperationalExcellence'
    }

    It 'adds MITRE mapping for security findings' {
        $security = $results | Where-Object RuleId -eq 'AVD-AZU-0001' | Select-Object -First 1
        @($security.MitreTactics).Count | Should -BeGreaterThan 0
        @($security.MitreTechniques).Count | Should -BeGreaterThan 0
    }

    It 'keeps MITRE mapping empty for non-security findings' {
        $validateFinding = $results | Where-Object RuleId -eq 'terraform-validate' | Select-Object -First 1
        @($validateFinding.MitreTactics).Count | Should -Be 0
        @($validateFinding.MitreTechniques).Count | Should -Be 0
    }

    It 'keeps baseline tags and framework values deduplicated' {
        $security = $results | Where-Object RuleId -eq 'AVD-AZU-0001' | Select-Object -First 1
        @($security.BaselineTags | Select-Object -Unique).Count | Should -Be @($security.BaselineTags).Count
        @($security.Frameworks | ForEach-Object { "$($_.kind)|$($_.controlId)" } | Select-Object -Unique).Count | Should -Be @($security.Frameworks).Count
    }

    It 'returns empty array for failed or empty tool output' {
        @(Normalize-IaCTerraform -ToolResult $failedFixture).Count | Should -Be 0
        @(Normalize-IaCTerraform -ToolResult ([PSCustomObject]@{ Source = 'terraform-iac'; Status = 'Success'; Findings = @() })).Count | Should -Be 0
    }
}
