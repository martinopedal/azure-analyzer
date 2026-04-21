#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-Gitleaks.ps1')

    $script:Fixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\gitleaks-output.json') -Raw | ConvertFrom-Json
    $script:FailedFixture = Get-Content (Join-Path $PSScriptRoot '..\fixtures\failed-output.json') -Raw | ConvertFrom-Json
}

Describe 'Normalize-Gitleaks' {
    BeforeAll {
        $script:Rows = @(Normalize-Gitleaks -ToolResult $script:Fixture)
    }

    It 'returns rows for successful tool output' {
        $script:Rows.Count | Should -Be 3
    }

    It 'uses Repository entity contract for dedup' {
        @($script:Rows | Where-Object { $_.EntityType -ne 'Repository' }).Count | Should -Be 0
        @($script:Rows | Where-Object { $_.Platform -ne 'GitHub' }).Count | Should -Be 0
        @($script:Rows | Where-Object { $_.EntityId -ne 'github.com/test-org/test-repo' }).Count | Should -Be 0
    }

    It 'sets SchemaVersion to 2.2 for all rows' {
        @($script:Rows | Where-Object { $_.SchemaVersion -ne '2.2' }).Count | Should -Be 0
    }

    It 'sets Source to gitleaks for all rows' {
        @($script:Rows | Where-Object { $_.Source -ne 'gitleaks' }).Count | Should -Be 0
    }

    It 'keeps all findings non-compliant' {
        @($script:Rows | Where-Object { $_.Compliant }).Count | Should -Be 0
    }

    It 'preserves RuleId values from wrapper output' {
        @($script:Rows | Where-Object { [string]::IsNullOrWhiteSpace($_.RuleId) }).Count | Should -Be 0
    }

    It 'preserves Title values from wrapper output' {
        @($script:Rows | Where-Object { [string]::IsNullOrWhiteSpace($_.Title) }).Count | Should -Be 0
    }

    It 'preserves Detail values from wrapper output' {
        @($script:Rows | Where-Object { [string]::IsNullOrWhiteSpace($_.Detail) }).Count | Should -Be 0
    }

    It 'preserves Remediation values from wrapper output' {
        @($script:Rows | Where-Object { [string]::IsNullOrWhiteSpace($_.Remediation) }).Count | Should -Be 0
    }

    It 'preserves LearnMoreUrl values from wrapper output' {
        @($script:Rows | Where-Object { [string]::IsNullOrWhiteSpace($_.LearnMoreUrl) }).Count | Should -Be 0
    }

    It 'maps severity ladder including Critical cloud credentials' {
        ($script:Rows | Where-Object RuleId -eq 'aws-access-key-id' | Select-Object -First 1).Severity | Should -Be 'Critical'
        ($script:Rows | Where-Object RuleId -eq 'generic-api-key' | Select-Object -First 1).Severity | Should -Be 'Medium'
    }

    It 'keeps private key findings at Medium severity' {
        ($script:Rows | Where-Object RuleId -eq 'private-key' | Select-Object -First 1).Severity | Should -Be 'Medium'
    }

    It 'maps Schema 2.2 fields end to end' {
        $aws = $script:Rows | Where-Object RuleId -eq 'aws-access-key-id' | Select-Object -First 1
        $workflow = $script:Rows | Where-Object RuleId -eq 'private-key' | Select-Object -First 1

        $aws.SchemaVersion | Should -Be '2.2'
        $aws.Pillar | Should -Be 'Security'
        $aws.Impact | Should -Be 'High'
        $aws.Effort | Should -Be 'Low'
        $aws.DeepLinkUrl | Should -Match 'gitleaks.toml'
        @($aws.Frameworks).Count | Should -BeGreaterThan 1
        $aws.BaselineTags | Should -Contain 'gitleaks:rule:aws-access-key-id'
        @($aws.EvidenceUris).Count | Should -BeGreaterThan 1
        @($aws.RemediationSnippets).Count | Should -BeGreaterThan 0
        $aws.ToolVersion | Should -Be '8.24.2'
        $workflow.EntityRefs | Should -Contain 'workflow:test-org/test-repo/.github/workflows/deploy.yml'
    }

    It 'maps Pillar Security for all findings' {
        @($script:Rows | Where-Object { $_.Pillar -ne 'Security' }).Count | Should -Be 0
    }

    It 'maps Low effort for all findings' {
        @($script:Rows | Where-Object { $_.Effort -ne 'Low' }).Count | Should -Be 0
    }

    It 'maps DeepLinkUrl to gitleaks rule documentation' {
        @($script:Rows | Where-Object { $_.DeepLinkUrl -notmatch 'gitleaks.toml' }).Count | Should -Be 0
    }

    It 'maps Frameworks to NIST and ISO references' {
        $first = $script:Rows | Select-Object -First 1
        @($first.Frameworks).Count | Should -BeGreaterThan 0
        @($first.Frameworks | Where-Object { $_.kind -eq 'ISO 27001' -and $_.controlId -eq 'A.9' }).Count | Should -BeGreaterThan 0
    }

    It 'maps BaselineTags from gitleaks rule IDs' {
        $first = $script:Rows | Select-Object -First 1
        @($first.BaselineTags | Where-Object { $_ -like 'gitleaks:rule:*' }).Count | Should -BeGreaterThan 0
    }

    It 'maps EvidenceUris with commit and blob links' {
        $first = $script:Rows | Select-Object -First 1
        @($first.EvidenceUris | Where-Object { $_ -match '/commit/' }).Count | Should -BeGreaterThan 0
        @($first.EvidenceUris | Where-Object { $_ -match '/blob/' }).Count | Should -BeGreaterThan 0
    }

    It 'maps remediation snippets as hashtables' {
        $first = $script:Rows | Select-Object -First 1
        @($first.RemediationSnippets).Count | Should -BeGreaterThan 0
        $first.RemediationSnippets[0].code | Should -Not -BeNullOrEmpty
    }

    It 'maps EntityRefs with repository reference' {
        $first = $script:Rows | Select-Object -First 1
        $first.EntityRefs | Should -Contain 'github.com/test-org/test-repo'
    }

    It 'maps ToolVersion from wrapper output' {
        @($script:Rows | Where-Object { $_.ToolVersion -ne '8.24.2' }).Count | Should -Be 0
    }

    It 'keeps ScoreDelta empty when wrapper does not emit it' {
        @($script:Rows | Where-Object { $null -ne $_.ScoreDelta }).Count | Should -Be 0
    }

    It 'keeps Mitre fields empty for gitleaks findings' {
        $first = $script:Rows | Select-Object -First 1
        @($first.MitreTactics).Count | Should -Be 0
        @($first.MitreTechniques).Count | Should -Be 0
    }

    It 'keeps subscription context empty for repository findings' {
        @($script:Rows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.SubscriptionId) }).Count | Should -Be 0
        @($script:Rows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.ResourceGroup) }).Count | Should -Be 0
    }

    It 'creates a shared provenance run id across findings' {
        @($script:Rows | ForEach-Object { $_.Provenance.RunId } | Select-Object -Unique).Count | Should -Be 1
    }

    It 'sets provenance source to gitleaks' {
        @($script:Rows | Where-Object { $_.Provenance.Source -ne 'gitleaks' }).Count | Should -Be 0
    }

    It 'keeps finding IDs stable from input records' {
        @($script:Rows | Where-Object { [string]::IsNullOrWhiteSpace($_.Id) }).Count | Should -Be 0
    }

    It 'normalizes ResourceId paths to lower slash format' {
        $script:Rows[2].ResourceId | Should -Be '.github/workflows/deploy.yml'
    }

    It 'normalizes all ResourceId paths to lowercase' {
        @($script:Rows | Where-Object { $_.ResourceId -cne $_.ResourceId.ToLowerInvariant() }).Count | Should -Be 0
    }

    It 'normalizes all ResourceId paths to forward slashes' {
        @($script:Rows | Where-Object { $_.ResourceId -match '\\' }).Count | Should -Be 0
    }

    It 'returns empty results for failed tool output' {
        $rows = @(Normalize-Gitleaks -ToolResult $script:FailedFixture)
        $rows.Count | Should -Be 0
    }
}
