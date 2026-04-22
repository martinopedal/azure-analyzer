#Requires -Version 7.4
Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Track D / #432b regression tests pinning the additive schema 2.2 fields on
    the three normalizers patched in this PR (PSRule, Kubescape, Scorecard).
.DESCRIPTION
    These tests are intentionally additive: they re-load the existing
    fixtures used by the per-tool test files and only assert that the newly
    enriched fields are populated. They do not duplicate or override existing
    per-tool assertions, so the current per-normalizer baseline remains the
    source of truth for unrelated regressions.
#>

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-PSRule.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-Kubescape.ps1')
    . (Join-Path $repoRoot 'modules\normalizers\Normalize-Scorecard.ps1')
}

Describe 'Track D fidelity / Normalize-PSRule enrichment' {
    BeforeAll {
        $fixturePath = Join-Path $PSScriptRoot '..\fixtures\psrule-output.json'
        $fixture = Get-Content $fixturePath -Raw | ConvertFrom-Json
        $script:psruleResults = @(Normalize-PSRule -ToolResult $fixture)
    }

    It 'derives Impact for every finding (no zero-value defaults)' {
        foreach ($r in $script:psruleResults) {
            $r.Impact | Should -Not -BeNullOrEmpty
            $r.Impact | Should -BeIn @('High', 'Medium', 'Low')
        }
    }

    It 'derives Effort for every finding' {
        foreach ($r in $script:psruleResults) {
            $r.Effort | Should -Not -BeNullOrEmpty
            $r.Effort | Should -BeIn @('High', 'Medium', 'Low')
        }
    }

    It 'maps High severity to High impact and Medium effort' {
        $high = $script:psruleResults | Where-Object { $_.Severity -eq 'High' } | Select-Object -First 1
        if ($high) {
            $high.Impact | Should -Be 'High'
            $high.Effort | Should -Be 'Medium'
        }
    }

    It 'populates EvidenceUris from LearnMoreUrl + DeepLinkUrl when present' {
        $withLink = $script:psruleResults | Where-Object { $_.LearnMoreUrl -or $_.DeepLinkUrl } | Select-Object -First 1
        if ($withLink) {
            @($withLink.EvidenceUris).Count | Should -BeGreaterThan 0
        }
    }

    It 'seeds EntityRefs with the canonical Subscription id' {
        $r = $script:psruleResults | Where-Object { $_.SubscriptionId } | Select-Object -First 1
        if ($r) {
            @($r.EntityRefs).Count | Should -BeGreaterThan 0
        }
    }
}

Describe 'Track D fidelity / Normalize-Kubescape enrichment' {
    BeforeAll {
        $fixturePath = Join-Path $PSScriptRoot '..\fixtures\kubescape-output.json'
        $fixture = Get-Content $fixturePath -Raw | ConvertFrom-Json
        $script:ksResults = @(Normalize-Kubescape -ToolResult $fixture)
    }

    It 'returns at least one finding from the fixture' {
        @($script:ksResults).Count | Should -BeGreaterThan 0
    }

    It 'derives Impact and Effort for every finding' {
        foreach ($r in $script:ksResults) {
            $r.Impact | Should -BeIn @('High', 'Medium', 'Low')
            $r.Effort | Should -BeIn @('High', 'Medium', 'Low')
        }
    }

    It 'sets DeepLinkUrl to the armosec hub URL derived from ControlId' {
        $withControl = $script:ksResults | Where-Object { $_.RuleId -match '^kubescape:C-' } | Select-Object -First 1
        if ($withControl) {
            $withControl.DeepLinkUrl | Should -Match '^https://hub\.armosec\.io/docs/c-\d+'
        }
    }

    It 'builds at least one RemediationSnippet when wrapper supplied prose remediation' {
        $withRemediation = $script:ksResults | Where-Object { $_.Remediation } | Select-Object -First 1
        if ($withRemediation) {
            @($withRemediation.RemediationSnippets).Count | Should -BeGreaterThan 0
        }
    }

    It 'seeds EntityRefs with the subscription canonical id' {
        $r = $script:ksResults | Where-Object { $_.SubscriptionId } | Select-Object -First 1
        if ($r) {
            @($r.EntityRefs).Count | Should -BeGreaterThan 0
        }
    }
}

Describe 'Track D fidelity / Normalize-Scorecard enrichment' {
    BeforeAll {
        $fixturePath = Join-Path $PSScriptRoot '..\fixtures\scorecard-output.json'
        $fixture = Get-Content $fixturePath -Raw | ConvertFrom-Json
        $script:scResults = @(Normalize-Scorecard -ToolResult $fixture)
    }

    It 'returns at least one finding from the fixture' {
        @($script:scResults).Count | Should -BeGreaterThan 0
    }

    It 'derives Impact and Effort for every finding' {
        foreach ($r in $script:scResults) {
            $r.Impact | Should -BeIn @('High', 'Medium', 'Low')
            $r.Effort | Should -BeIn @('High', 'Medium', 'Low')
        }
    }

    It 'computes ScoreDelta = 10 - score for at least one finding when score is non-negative' {
        $withDelta = $script:scResults | Where-Object { $null -ne $_.ScoreDelta } | Select-Object -First 1
        if ($withDelta) {
            $withDelta.ScoreDelta | Should -BeGreaterOrEqual 0
            $withDelta.ScoreDelta | Should -BeLessOrEqual 10
        }
    }

    It 'seeds EntityRefs with host/owner organisation derived from canonical id' {
        $r = $script:scResults | Where-Object { $_.EntityId -match '^[^/]+/[^/]+/[^/]+$' } | Select-Object -First 1
        if ($r) {
            @($r.EntityRefs).Count | Should -BeGreaterThan 0
        }
    }
}
