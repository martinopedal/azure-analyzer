#Requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
    $script:WorkflowPath = Join-Path $script:RepoRoot '.github' 'workflows' 'closes-link-required.yml'
    $script:WorkflowText = Get-Content -Raw -Path $script:WorkflowPath
}

Describe 'closes-link-required workflow contract' {
    It 'supports bypass with skip-closes-check label' {
        $script:WorkflowText | Should -Match "skip-closes-check"
    }

    It 'skips release-please branches' {
        $script:WorkflowText | Should -Match '\^release-please--'
    }

    It 'exempts expected bot authors' {
        foreach ($author in @('github-actions\[bot\]', 'dependabot\[bot\]', 'copilot-swe-agent\[bot\]', 'copilot-swe-agent')) {
            $script:WorkflowText | Should -Match $author
        }
    }

    It 'still enforces Closes/Fixes/Resolves or N/A for non-exempt PRs' {
        $script:WorkflowText | Should -Match "PR body must contain a 'Closes #N' \(or Fixes/Resolves\) link, or an explicit 'N/A' justification"
    }
}
