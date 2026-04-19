#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' '..' 'modules' 'shared' 'Invoke-PRReviewGate.ps1'
}

Describe 'Invoke-PRReviewGate shared helper' {
    BeforeEach {
        Mock -CommandName Invoke-WebRequest -MockWith { throw 'Invoke-WebRequest should not be called in these tests.' }

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)] $Arguments)
            $joined = [string]($Arguments -join ' ')
            if ($joined -match '/pulls/105/reviews') {
                return '[[
                    {
                        "id": 1001,
                        "state": "CHANGES_REQUESTED",
                        "body": "Please fix validation",
                        "submitted_at": "2026-04-17T10:00:00Z",
                        "commit_id": "abc123",
                        "user": { "login": "copilot-pull-request-reviewer[bot]" }
                    },
                    {
                        "id": 1002,
                        "state": "COMMENTED",
                        "body": "Optional hardening note",
                        "submitted_at": "2026-04-17T10:01:00Z",
                        "commit_id": "def456",
                        "user": { "login": "human-reviewer" }
                    }
                ]]'
            }

            if ($joined -match '/pulls/105/comments') {
                return '[[
                    {
                        "id": 2001,
                        "body": "Escape untrusted input",
                        "path": ".github/workflows/pr-review-gate.yml",
                        "line": 27,
                        "side": "RIGHT",
                        "created_at": "2026-04-17T10:02:00Z",
                        "pull_request_review_id": 1001,
                        "user": { "login": "copilot-pull-request-reviewer[bot]" }
                    }
                ]]'
            }

            if ($joined -match 'pr comment') {
                return 'comment posted'
            }

            throw "Unexpected gh call: $joined"
        }

        . $script:ModulePath
    }

    AfterEach {
        Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
    }

    It 'Get-TriageModels returns exactly the three frontier models' {
        $models = @(Get-TriageModels)
        $models.Count | Should -Be 3
        $names = @($models | ForEach-Object { $_.Name })
        $names | Should -Contain 'claude-opus-4.7'
        $names | Should -Contain 'gpt-5.3-codex'
        $names | Should -Contain 'goldeneye'
        $names | Should -Not -Contain 'claude-opus-4.6'
        $names | Should -Not -Contain 'claude-opus-4.5'
        $names | Should -Not -Contain 'claude-sonnet-4.5'
    }

    It 'Get-PRReviewFeedback parses paginated gh review and line comment payloads' {
        $feedback = Get-PRReviewFeedback -PRNumber 105 -Repo 'martinopedal/azure-analyzer'

        $feedback.PRNumber | Should -Be 105
        $feedback.Reviews.Count | Should -Be 2
        $feedback.Reviews[0].Reviewer | Should -Be 'copilot-pull-request-reviewer[bot]'
        $feedback.Reviews[0].State | Should -Be 'CHANGES_REQUESTED'
        $feedback.LineComments.Count | Should -Be 1
        $feedback.LineComments[0].Path | Should -Be '.github/workflows/pr-review-gate.yml'
        $feedback.LineComments[0].Line | Should -Be 27
    }

    It 'Save-ReviewPlan writes all required sections to consensus markdown file' {
        $outputPath = Join-Path $TestDrive 'inbox'
        $consensus = [PSCustomObject]@{
            ReviewerVerdict          = 'CHANGES_REQUESTED'
            ConsensusFindings        = @([PSCustomObject]@{ title = 'Fix expression safety'; detail = 'Avoid direct interpolation'; path = 'file.ps1'; line = 11; severity = 'High' })
            DisputedFindings         = @([PSCustomObject]@{ title = 'Rate limit handling'; detail = 'Needs more retries'; path = 'file.ps1'; line = 25; severity = 'Medium' })
            ActionPlan               = @('Harden workflow env passing', 'Add retry handling')
            LockedOutAgent           = 'copilot-swe-agent[bot]'
            RecommendedRevisionOwner = 'forge'
        }

        $result = Save-ReviewPlan -Consensus $consensus -PRNumber 105 -OutputPath $outputPath -Agent 'sentinel'

        Test-Path $result.Path | Should -BeTrue
        $content = Get-Content -Path $result.Path -Raw
        $content | Should -Match '## Reviewer Verdict'
        $content | Should -Match '## Consensus Findings'
        $content | Should -Match '## Disputed Findings'
        $content | Should -Match '## Action Plan'
        $content | Should -Match '## Reviewer Lockout Notice'
    }

    It 'DryRun prevents file writes for plan and triage bundle outputs' {
        $outputPath = Join-Path $TestDrive 'inbox'
        $feedback = [PSCustomObject]@{
            Repo         = 'martinopedal/azure-analyzer'
            PRNumber     = 105
            GeneratedAt  = '2026-04-17T10:00:00Z'
            Reviews      = @()
            LineComments = @()
            Summary      = [PSCustomObject]@{}
        }
        $consensus = [PSCustomObject]@{
            ReviewerVerdict          = 'COMMENTED'
            ConsensusFindings        = @()
            DisputedFindings         = @()
            ActionPlan               = @('noop')
            LockedOutAgent           = 'copilot-swe-agent[bot]'
            RecommendedRevisionOwner = 'forge'
        }

        $bundle = Invoke-MultiModelTriage -FeedbackPayload $feedback -OutputPath $outputPath -DryRun
        $plan = Save-ReviewPlan -Consensus $consensus -PRNumber 106 -OutputPath $outputPath -Agent 'sentinel-dryrun' -DryRun

        Test-Path $bundle.BundlePath | Should -BeFalse
        Test-Path $plan.Path | Should -BeFalse
    }
}
