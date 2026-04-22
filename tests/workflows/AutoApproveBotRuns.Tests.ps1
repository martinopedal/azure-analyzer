#Requires -Version 7.4
<#
Invariant guard for .github/workflows/auto-approve-bot-runs.yml. Locks down
the security-sensitive shape of the workflow so a future edit cannot:
  - widen the trigger beyond workflow_run / requested
  - escalate permissions beyond actions:write
  - drop the trusted allow-list to data-driven sources
  - remove the action_required gating check
#>

BeforeAll {
    if (-not (Get-Module -ListAvailable powershell-yaml)) {
        Install-Module powershell-yaml -Scope CurrentUser -Force -SkipPublisherCheck -ErrorAction Stop | Out-Null
    }
    Import-Module powershell-yaml -ErrorAction Stop
    $script:RepoRoot = Join-Path $PSScriptRoot '..' '..'
    $script:WorkflowPath = Join-Path $script:RepoRoot '.github' 'workflows' 'auto-approve-bot-runs.yml'
    $script:WorkflowText = Get-Content -Raw $script:WorkflowPath
    $script:Workflow = ConvertFrom-Yaml $script:WorkflowText
    $script:OnBlock = if ($script:Workflow.ContainsKey('on')) { $script:Workflow['on'] } else { $script:Workflow[$true] }
}

Describe 'Auto-approve bot workflow runs' {
    It 'workflow file exists' {
        Test-Path $script:WorkflowPath | Should -BeTrue
    }

    It 'triggers only on workflow_run requested events' {
        $script:OnBlock.Keys | Should -HaveCount 1
        $script:OnBlock.ContainsKey('workflow_run') | Should -BeTrue
        @($script:OnBlock['workflow_run']['types']) | Should -Contain 'requested'
        @($script:OnBlock['workflow_run']['types']).Count | Should -Be 1
    }

    It 'declares minimal permissions (actions:write only beyond read)' {
        $perms = $script:Workflow['permissions']
        $perms['actions'] | Should -Be 'write'
        $perms['pull-requests'] | Should -Be 'read'
        $perms['contents'] | Should -Be 'read'
        foreach ($k in $perms.Keys) {
            if ($k -ne 'actions' -and $perms[$k] -eq 'write') {
                throw "Unexpected write permission on '$k'"
            }
        }
    }

    It 'has a concurrency guard' {
        $script:Workflow.ContainsKey('concurrency') | Should -BeTrue
        $script:Workflow['concurrency']['group'] | Should -Match 'auto-approve-bot-runs'
    }

    It 'hard-codes a trusted actor allow-list (not sourced from PR content)' {
        $script:WorkflowText | Should -Match 'copilot-swe-agent\[bot\]'
        $script:WorkflowText | Should -Match 'dependabot\[bot\]'
        $script:WorkflowText | Should -Match 'martinopedal'
        $script:WorkflowText | Should -Not -Match 'github\.event\.pull_request\.user'
        $script:WorkflowText | Should -Not -Match 'workflow_dispatch'
    }

    It 'gates approval on action_required status before calling approve' {
        $script:WorkflowText | Should -Match 'action_required'
        $script:WorkflowText | Should -Match '/approve'
    }

    It 'watches the critical squad workflows' {
        $watched = @($script:OnBlock['workflow_run']['workflows'])
        foreach ($required in @('CI', 'CodeQL', 'Docs Check', 'Markdown Check', 'Copilot Agent PR Review')) {
            $watched | Should -Contain $required -Because "auto-approve must cover the $required workflow"
        }
    }
}
