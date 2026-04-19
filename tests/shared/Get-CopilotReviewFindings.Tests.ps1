#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' '..' 'modules' 'shared' 'Get-CopilotReviewFindings.ps1'
    $script:FixturePath = Join-Path $PSScriptRoot '..' 'fixtures' 'copilot-review' 'reviewThreads-page1.json'
}

Describe 'Get-CopilotReviewFindings' {
    BeforeEach {
        $script:GhCalls = [System.Collections.Generic.List[string]]::new()
        $script:FixtureJson = Get-Content -Path $script:FixturePath -Raw -Encoding utf8

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)] [object[]] $Arguments)
            $joined = [string]($Arguments -join ' ')
            $script:GhCalls.Add($joined) | Out-Null
            if ($joined -match '^api graphql') {
                return $script:FixtureJson
            }
            throw "Unexpected gh call: $joined"
        }

        . $script:ModulePath
    }

    AfterEach {
        Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
    }

    It 'returns Copilot-authored findings with required shape' {
        $findings = @(Get-CopilotReviewFindings -Owner 'martinopedal' -Repo 'azure-analyzer' -PullNumber 172)

        $findings.Count | Should -Be 4
        $findings[0].PSObject.Properties.Name | Should -Contain 'Id'
        $findings[0].PSObject.Properties.Name | Should -Contain 'Path'
        $findings[0].PSObject.Properties.Name | Should -Contain 'Line'
        $findings[0].PSObject.Properties.Name | Should -Contain 'Body'
        $findings[0].PSObject.Properties.Name | Should -Contain 'Category'
        $findings[0].PSObject.Properties.Name | Should -Contain 'Severity'
        $findings[0].PSObject.Properties.Name | Should -Contain 'ThreadId'
        $findings[0].PSObject.Properties.Name | Should -Contain 'IsResolved'
        $findings[0].PSObject.Properties.Name | Should -Contain 'IsOutdated'
    }

    It 'filters to authors containing copilot (case-insensitive)' {
        $findings = @(Get-CopilotReviewFindings -Owner 'martinopedal' -Repo 'azure-analyzer' -PullNumber 172)

        foreach ($f in $findings) {
            $f.Id | Should -Match 'COMMENT_'
        }
        @($findings | Where-Object { $_.Id -match 'COMMENT_correctness_reply' }).Count | Should -Be 0
    }

    It 'defaults category to correctness when not tagged' {
        $findings = @(Get-CopilotReviewFindings -Owner 'martinopedal' -Repo 'azure-analyzer' -PullNumber 172)
        $item = $findings | Where-Object { $_.Id -match 'THREAD_correctness:COMMENT_correctness' } | Select-Object -First 1
        $item.Category | Should -Be 'correctness'
        $item.Severity | Should -Be 'Medium'
    }

    It 'marks thread HasRejectionReply when a multi-model rejection comment exists' {
        $findings = @(Get-CopilotReviewFindings -Owner 'martinopedal' -Repo 'azure-analyzer' -PullNumber 172)
        $item = $findings | Where-Object { $_.ThreadId -eq 'THREAD_correctness' } | Select-Object -First 1
        $item.HasRejectionReply | Should -BeTrue
    }

    It 'calls gh graphql through the shared GraphQL wrapper path' {
        Get-CopilotReviewFindings -Owner 'martinopedal' -Repo 'azure-analyzer' -PullNumber 172 | Out-Null
        @($script:GhCalls | Where-Object { $_ -match '^api graphql' }).Count | Should -Be 1
    }
}

