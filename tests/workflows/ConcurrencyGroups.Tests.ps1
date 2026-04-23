# Convention test: CI/PR-reactive workflows must declare a top-level `concurrency:` block
# so that superseded runs are cancelled and queue contention is bounded.
#
# Background: without a concurrency group, every push to a PR branch kicks off a new
# independent run while prior runs keep burning minutes until their own jobs complete.
# A group keyed by `${{ github.workflow }}-${{ github.ref }}` coalesces runs per ref
# so only the newest commit is evaluated.
#
# Halberd contract (CAT-E sweep): the workflows enumerated in $RequiredWorkflows below
# must declare concurrency. Scheduled-only or one-shot workflows (release, scan) are
# out of scope.

Describe 'Workflow concurrency contract' {

    BeforeDiscovery {
        $script:WorkflowDir = Join-Path $PSScriptRoot '..' '..' '.github' 'workflows'
        $script:WorkflowDir = (Resolve-Path $script:WorkflowDir).Path

        # Workflows that MUST declare concurrency. Keep in sync with the Halberd
        # CAT-E audit; additions should land in the same PR that introduces the
        # new PR-reactive workflow.
        $script:RequiredWorkflows = @(
            'bicep-build.yml',
            'ci.yml',
            'codeql.yml',
            'docs-check.yml',
            'markdown-check.yml',
            'stub-deadline-check.yml',
            'copilot-agent-pr-review.yml',
            'pr-review-gate.yml',
            'pr-advisory-gate.yml'
        ) | ForEach-Object { @{ Name = $_; Path = (Join-Path $script:WorkflowDir $_) } }
    }

    It 'declares a top-level concurrency block in <Name>' -ForEach $script:RequiredWorkflows {

        param($Name, $Path)

        $Path | Should -Exist

        $lines = Get-Content -Path $Path
        $concurrencyLine = $lines | Where-Object { $_ -match '^concurrency:\s*$' }

        $concurrencyLine | Should -Not -BeNullOrEmpty -Because "$Name must declare a top-level ``concurrency:`` block so superseded runs are cancelled"
    }

    It 'declares a concurrency group expression in <Name>' -ForEach $script:RequiredWorkflows {

        param($Name, $Path)

        $content = Get-Content -Path $Path -Raw

        $content | Should -Match '(?ms)^concurrency:\s*\r?\n\s+group:\s+\S+' -Because "$Name concurrency block must set a ``group:`` expression"
    }
}
