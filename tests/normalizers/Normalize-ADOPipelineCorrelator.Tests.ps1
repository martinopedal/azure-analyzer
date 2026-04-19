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
