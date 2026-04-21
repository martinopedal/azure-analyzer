#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-ADOPipelineCorrelator.ps1')
}

Describe 'Normalize-ADOPipelineCorrelator' {
    BeforeAll {
        $fixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\ado-pipeline-correlation\ado-pipeline-correlator-output.json') -Raw | ConvertFrom-Json
        $failedFixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\failed-output.json') -Raw | ConvertFrom-Json
    }

    It 'returns normalized pipeline correlation findings' {
        $rows = @(Normalize-ADOPipelineCorrelator -ToolResult $fixture)
        $rows.Count | Should -Be 2
        ($rows | Select-Object -ExpandProperty Source -Unique) | Should -Be 'ado-pipeline-correlator'
        ($rows | Select-Object -ExpandProperty EntityType -Unique) | Should -Be 'Pipeline'
        ($rows | Select-Object -ExpandProperty Platform -Unique) | Should -Be 'ADO'
        ($rows | Select-Object -ExpandProperty Pillar -Unique) | Should -Be 'Security'
        ($rows | Select-Object -ExpandProperty Effort -Unique) | Should -Be 'Medium'
    }

    It 'maps Schema 2.2 correlation metadata and entity refs' {
        $rows = @(Normalize-ADOPipelineCorrelator -ToolResult $fixture)
        $direct = $rows | Where-Object { $_.Id -eq 'corr-1' } | Select-Object -First 1
        $uncorrelated = $rows | Where-Object { $_.Id -eq 'corr-2' } | Select-Object -First 1

        $direct.Impact | Should -Be 'High'
        $uncorrelated.Impact | Should -Be 'Low'
        $direct.DeepLinkUrl | Should -Be 'https://dev.azure.com/contoso/payments/_build/results?buildId=1001&view=results'
        @($direct.EvidenceUris) | Should -Contain 'https://dev.azure.com/contoso/payments/_build/results?buildId=1001'
        @($direct.EvidenceUris) | Should -Contain 'https://dev.azure.com/contoso/payments/_build/results?buildId=1001&view=logs'
        @($direct.BaselineTags) | Should -Contain 'correlated-direct'
        @($direct.BaselineTags) | Should -Contain 'secret-category:github-pat'
        @($direct.EntityRefs) | Should -Contain 'finding:secret-1'
        @($direct.EntityRefs) | Should -Contain 'pipeline:ado://contoso/payments/pipeline/55'
        @($direct.EntityRefs) | Should -Contain 'build:1001'
        @($direct.EntityRefs) | Should -Contain 'repository:ado://contoso/payments/repository/payments-api'
        @($direct.EntityRefs) | Should -Contain 'commit:aaaaaaaa11111111'
        @($direct.EntityRefs) | Should -Contain 'AzureDevOps|Pipeline|contoso/payments/Pipeline/55'
        @($direct.RemediationSnippets).Count | Should -Be 1
        $direct.RemediationSnippets[0].language | Should -Be 'text'
        $direct.ToolVersion | Should -Be 'azure-devops/1.0.1'
    }

    It 'keeps titles keyed by build and secret finding for dedup safety' {
        $rows = @(Normalize-ADOPipelineCorrelator -ToolResult $fixture)
        @($rows | Where-Object { $_.Title -match '\[build:[^\]]+ secret:[^\]]+\]' }).Count | Should -Be 2
    }

    It 'normalizes severity case-insensitively' {
        $input = [PSCustomObject]@{
            Status = 'Success'
            Findings = @(
                [PSCustomObject]@{ Id='1'; Title='a'; Severity='critical'; Compliant=$false; Detail=''; Remediation=''; LearnMoreUrl=''; PipelineResourceId='ado://o/p/pipeline/1'; ResourceId='ado://o/p/pipeline/1' },
                [PSCustomObject]@{ Id='2'; Title='b'; Severity='HIGH'; Compliant=$false; Detail=''; Remediation=''; LearnMoreUrl=''; PipelineResourceId='ado://o/p/pipeline/2'; ResourceId='ado://o/p/pipeline/2' },
                [PSCustomObject]@{ Id='3'; Title='c'; Severity='Medium'; Compliant=$false; Detail=''; Remediation=''; LearnMoreUrl=''; PipelineResourceId='ado://o/p/pipeline/3'; ResourceId='ado://o/p/pipeline/3' },
                [PSCustomObject]@{ Id='4'; Title='d'; Severity='low'; Compliant=$false; Detail=''; Remediation=''; LearnMoreUrl=''; PipelineResourceId='ado://o/p/pipeline/4'; ResourceId='ado://o/p/pipeline/4' },
                [PSCustomObject]@{ Id='5'; Title='e'; Severity='Info'; Compliant=$false; Detail=''; Remediation=''; LearnMoreUrl=''; PipelineResourceId='ado://o/p/pipeline/5'; ResourceId='ado://o/p/pipeline/5' }
            )
        }
        $rows = @(Normalize-ADOPipelineCorrelator -ToolResult $input)
        ($rows | Where-Object Severity -eq 'Critical').Count | Should -Be 1
        ($rows | Where-Object Severity -eq 'High').Count | Should -Be 1
        ($rows | Where-Object Severity -eq 'Medium').Count | Should -Be 1
        ($rows | Where-Object Severity -eq 'Low').Count | Should -Be 1
        ($rows | Where-Object Severity -eq 'Info').Count | Should -Be 1
    }

    It 'returns empty array for failed wrapper output' {
        @(Normalize-ADOPipelineCorrelator -ToolResult $failedFixture).Count | Should -Be 0
    }
}
