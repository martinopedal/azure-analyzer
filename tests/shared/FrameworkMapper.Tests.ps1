#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\FrameworkMapper.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
}

Describe 'FrameworkMapper' {
    It 'maps known azqr finding title to CIS/NIST/PCI controls' {
        $finding = New-FindingRow -Id 'f-azqr' -Source 'azqr' -EntityId 'azqr/x' -EntityType 'AzureResource' -Title 'VM does not have Azure Disk Encryption enabled' -Compliant $false -ProvenanceRunId 'run-1' -Category 'Security' -Severity 'High'
        $enriched = Add-FrameworkMetadataToFinding -Finding $finding

        @($enriched.Frameworks).Count | Should -Be 3
        @($enriched.Controls) | Should -Contain 'CIS: 7.1'
        @($enriched.Controls) | Should -Contain 'NIST: SC-28'
        @($enriched.Controls) | Should -Contain 'PCI: 3.5.1'
    }

    It 'maps known psrule category rule key' {
        $finding = New-FindingRow -Id 'f-psrule' -Source 'psrule' -EntityId 'psrule/x' -EntityType 'AzureResource' -Title 'SQL Database should have Transparent Data Encryption enabled' -Compliant $false -ProvenanceRunId 'run-2' -Category 'Azure.SQL.TDE' -Severity 'High'
        $enriched = Add-FrameworkMetadataToFinding -Finding $finding

        @($enriched.Frameworks | ForEach-Object { $_.framework }) | Should -Contain 'CIS'
        @($enriched.Frameworks | ForEach-Object { $_.control }) | Should -Contain '4.2'
    }

    It 'leaves unknown findings without framework mappings' {
        $finding = New-FindingRow -Id 'f-none' -Source 'azqr' -EntityId 'azqr/none' -EntityType 'AzureResource' -Title 'Completely unmapped control title' -Compliant $false -ProvenanceRunId 'run-3' -Category 'Unknown' -Severity 'Low'
        $enriched = Add-FrameworkMetadataToFinding -Finding $finding

        @($enriched.Frameworks).Count | Should -Be 0
        @($enriched.Controls).Count | Should -Be 0
    }

    It 'scopes findings to selected framework' {
        $findings = @(
            (New-FindingRow -Id 'f1' -Source 'azqr' -EntityId 'azqr/1' -EntityType 'AzureResource' -Title 'VM does not have Azure Disk Encryption enabled' -Compliant $false -ProvenanceRunId 'run-4' -Category 'Security' -Severity 'High'),
            (New-FindingRow -Id 'f2' -Source 'azqr' -EntityId 'azqr/2' -EntityType 'AzureResource' -Title 'Unmapped finding' -Compliant $false -ProvenanceRunId 'run-4' -Category 'Security' -Severity 'Low')
        )
        $enriched = Add-FrameworkMetadata -Findings $findings
        $scoped = Select-FindingsByFramework -Findings $enriched -Framework 'NIST'

        @($scoped).Count | Should -Be 1
        @($scoped[0].Frameworks | ForEach-Object { $_.framework } | Sort-Object -Unique) | Should -Be @('NIST')
        @($scoped[0].Controls) | Should -Contain 'NIST: SC-28'
    }

    It 'returns framework coverage totals based on mapped catalog controls' {
        $findings = @(
            (New-FindingRow -Id 'f1' -Source 'azqr' -EntityId 'azqr/1' -EntityType 'AzureResource' -Title 'VM does not have Azure Disk Encryption enabled' -Compliant $false -ProvenanceRunId 'run-5' -Category 'Security' -Severity 'High'),
            (New-FindingRow -Id 'f2' -Source 'scorecard' -EntityId 'scorecard/1' -EntityType 'Repository' -Title 'Branch protection is not enabled on default branch' -Compliant $false -ProvenanceRunId 'run-5' -Category 'Supply Chain' -Severity 'High')
        )
        $enriched = Add-FrameworkMetadata -Findings $findings
        $coverage = @(Get-FrameworkCoverage -Findings $enriched)

        @($coverage).Count | Should -Be 3
        $cis = @($coverage | Where-Object { $_.Framework -eq 'CIS' })[0]
        $cis.CoveredControls | Should -BeGreaterThan 0
        $cis.TotalControls | Should -BeGreaterThan 0
    }
}
