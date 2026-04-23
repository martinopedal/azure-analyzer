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

    It 'ignores stale LASTEXITCODE when gh is mocked' {
        $previous = $global:LASTEXITCODE
        try {
            $global:LASTEXITCODE = 1
            $feedback = Get-PRReviewFeedback -PRNumber 105 -Repo 'martinopedal/azure-analyzer'
            $feedback.Reviews.Count | Should -Be 2
            $feedback.LineComments.Count | Should -Be 1
        } finally {
            $global:LASTEXITCODE = $previous
        }
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

    Context 'null-safe model response handling' {
        It 'Get-ModelResponses returns @() when no path or env is set' {
            $previous = $env:PR_REVIEW_GATE_RESPONSES_JSON
            try {
                $env:PR_REVIEW_GATE_RESPONSES_JSON = $null
                $result = @(Get-ModelResponses)
                $result.Count | Should -Be 0
            } finally {
                $env:PR_REVIEW_GATE_RESPONSES_JSON = $previous
            }
        }

        It 'Get-ModelResponses returns @() when env contains JSON null' {
            $previous = $env:PR_REVIEW_GATE_RESPONSES_JSON
            try {
                $env:PR_REVIEW_GATE_RESPONSES_JSON = 'null'
                $result = @(Get-ModelResponses)
                $result.Count | Should -Be 0
            } finally {
                $env:PR_REVIEW_GATE_RESPONSES_JSON = $previous
            }
        }

        It 'Get-ModelResponses returns @() when env contains empty JSON array' {
            $previous = $env:PR_REVIEW_GATE_RESPONSES_JSON
            try {
                $env:PR_REVIEW_GATE_RESPONSES_JSON = '[]'
                $result = @(Get-ModelResponses)
                $result.Count | Should -Be 0
            } finally {
                $env:PR_REVIEW_GATE_RESPONSES_JSON = $previous
            }
        }

        It 'ConvertTo-TriageResponse returns $null when input is $null' {
            $result = ConvertTo-TriageResponse -Response $null
            $result | Should -BeNullOrEmpty
        }

        It 'Merge-TriageResponses tolerates a Responses array containing $null elements' {
            $feedback = [PSCustomObject]@{
                Repo         = 'martinopedal/azure-analyzer'
                PRNumber     = 200
                Reviews      = @()
                LineComments = @()
                Summary      = [PSCustomObject]@{}
            }
            $consensus = Merge-TriageResponses -FeedbackPayload $feedback -Responses @($null, $null) -LockedOutAgent 'martinopedal'
            $consensus.ReviewerVerdict | Should -Be 'COMMENTED'
            $consensus.RecommendedRevisionOwner | Should -Not -Be 'martinopedal'
        }

        It 'Merge-TriageResponses tolerates an empty Responses array' {
            $feedback = [PSCustomObject]@{
                Repo         = 'martinopedal/azure-analyzer'
                PRNumber     = 201
                Reviews      = @()
                LineComments = @()
                Summary      = [PSCustomObject]@{}
            }
            $consensus = Merge-TriageResponses -FeedbackPayload $feedback -Responses @() -LockedOutAgent 'martinopedal'
            $consensus.ReviewerVerdict | Should -Be 'COMMENTED'
        }
    }

    Context 'End-to-end DryRun gate without model responses (regression #507)' {
        # Reproduces the workflow scenario at SHA 0ce933a where the gate ran on
        # a `pull_request_review_comment` event with no model response artifacts
        # available. Failed with: "Cannot bind argument to parameter 'Response'
        # because it is null." Fixes #517 (null-safe responses) + #584 (sparse
        # user payloads) jointly resolve this; this test locks in the chained
        # path end-to-end.
        BeforeEach {
            $script:OriginalResponsesEnv = $env:PR_REVIEW_GATE_RESPONSES_JSON
            $env:PR_REVIEW_GATE_RESPONSES_JSON = $null
        }

        AfterEach {
            $env:PR_REVIEW_GATE_RESPONSES_JSON = $script:OriginalResponsesEnv
        }

        It 'returns Status=Success when responses env is unset and reviews include sparse .user' {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)] $Arguments)
                $joined = [string]($Arguments -join ' ')
                if ($joined -match '/pulls/507/reviews') {
                    return '[[
                        { "id": 5070, "state": "COMMENTED", "body": "no user", "submitted_at": "2026-04-22T22:00:00Z", "commit_id": "0ce933a" }
                    ]]'
                }
                if ($joined -match '/pulls/507/comments') {
                    return '[[
                        { "id": 5071, "body": "missing user", "path": "README.md", "line": 1, "side": "RIGHT", "created_at": "2026-04-22T22:00:01Z" }
                    ]]'
                }
                throw "Unexpected gh call: $joined"
            }
            . $script:ModulePath

            $result = Invoke-PRReviewGate -PRNumber 507 -Repo 'martinopedal/azure-analyzer' `
                -OutputPath (Join-Path $TestDrive 'inbox') -PRAuthorAgent 'martinopedal' -DryRun
            $result.Status | Should -Be 'Success'
            $result.Consensus.RecommendedRevisionOwner | Should -Not -Be 'martinopedal'
        }
    }

    Context 'Invoke-GhApiPaged survives credential-like patterns inside diff_hunk (regression #842)' {
        # Reproduces the CI failure where Remove-Credentials ran on raw JSON
        # text before ConvertFrom-Json. Greedy regex patterns like
        # Password=[^;]+ consumed past the closing " of diff_hunk values,
        # producing "Unterminated string" parse errors.
        BeforeEach {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)] $Arguments)
                $joined = [string]($Arguments -join ' ')
                if ($joined -match '/pulls/842/reviews') {
                    return '[[{ "id": 8420, "state": "COMMENTED", "body": "lgtm", "submitted_at": "2026-04-23T15:00:00Z", "commit_id": "abc123", "user": { "login": "reviewer" } }]]'
                }
                if ($joined -match '/pulls/842/comments') {
                    # diff_hunk deliberately contains Password=... which would
                    # have been corrupted by Remove-Credentials before parsing.
                    return '[[{ "id": 8421, "body": "fix creds", "path": "config.ps1", "line": 5, "side": "RIGHT", "created_at": "2026-04-23T15:01:00Z", "user": { "login": "copilot-pull-request-reviewer[bot]" }, "diff_hunk": "@@ -1,3 +1,3 @@\n-Password=OldSecret123\n+Password=$env:VAULT_SECRET", "pull_request_review_id": 8420 }]]'
                }
                throw "Unexpected gh call: $joined"
            }
            . $script:ModulePath
        }

        It 'parses line comments whose diff_hunk contains credential-like patterns' {
            $feedback = Get-PRReviewFeedback -PRNumber 842 -Repo 'martinopedal/azure-analyzer'
            $feedback.LineComments.Count | Should -Be 1
            $feedback.LineComments[0].Body | Should -Be 'fix creds'
            $feedback.LineComments[0].Path | Should -Be 'config.ps1'
        }
    }

    Context 'Get-PullRequestFeedback tolerates sparse .user payloads (regression #584)' {
        BeforeEach {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)] $Arguments)
                $joined = [string]($Arguments -join ' ')
                if ($joined -match '/pulls/584/reviews') {
                    return '[[
                        { "id": 9001, "state": "COMMENTED", "body": "ghost review", "submitted_at": "2026-04-23T03:00:00Z", "commit_id": "deadbeef" },
                        { "id": 9002, "state": "APPROVED", "body": "null user", "submitted_at": "2026-04-23T03:01:00Z", "commit_id": "cafe", "user": null }
                    ]]'
                }
                if ($joined -match '/pulls/584/comments') {
                    return '[[
                        { "id": 9101, "body": "no user property", "path": "x.ps1", "line": 1, "side": "RIGHT", "created_at": "2026-04-23T03:02:00Z" },
                        { "id": 9102, "body": "user is null", "path": "y.ps1", "line": 2, "side": "RIGHT", "created_at": "2026-04-23T03:03:00Z", "user": null }
                    ]]'
                }
                throw "Unexpected gh call: $joined"
            }
            . $script:ModulePath
        }

        It 'does not throw under StrictMode and falls back to unknown-reviewer' {
            { Get-PRReviewFeedback -Repo 'martinopedal/azure-analyzer' -PRNumber 584 } | Should -Not -Throw
            $feedback = Get-PRReviewFeedback -Repo 'martinopedal/azure-analyzer' -PRNumber 584
            $feedback.Reviews.Count | Should -Be 2
            $feedback.Reviews[0].Reviewer | Should -Be 'unknown-reviewer'
            $feedback.Reviews[1].Reviewer | Should -Be 'unknown-reviewer'
            $feedback.LineComments.Count | Should -Be 2
            $feedback.LineComments[0].Reviewer | Should -Be 'unknown-reviewer'
            $feedback.LineComments[1].Reviewer | Should -Be 'unknown-reviewer'
        }
    }
}
