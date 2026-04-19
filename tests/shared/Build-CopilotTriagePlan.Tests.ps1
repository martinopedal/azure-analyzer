#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' '..' 'modules' 'shared' 'Build-CopilotTriagePlan.ps1'
    $script:FixturePath = Join-Path $PSScriptRoot '..' 'fixtures' 'copilot-review' 'findings-sample.json'
    . $script:ModulePath
}

Describe 'Build-CopilotTriagePlan' {
    BeforeEach {
        $script:Findings = @(Get-Content -Path $script:FixturePath -Raw -Encoding utf8 | ConvertFrom-Json)
    }

    It 'groups findings by normalized category and deduplicates identical entries' {
        $plan = Build-CopilotTriagePlan -Findings $script:Findings -DiffContext 'diff snippet'
        $categories = @($plan.Items | ForEach-Object { $_.Category })

        $categories | Should -Contain 'blocker'
        $categories | Should -Contain 'correctness'
        $categories | Should -Contain 'style'
        $categories | Should -Contain 'nit'
        $plan.Summary.TotalFindings | Should -Be 4
        ($plan.Items | Where-Object Category -eq 'correctness' | Select-Object -First 1).Count | Should -Be 1
    }

    It 'computes a stable plan hash regardless of input ordering' {
        $plan1 = Build-CopilotTriagePlan -Findings $script:Findings -DiffContext 'diff snippet'
        $shuffled = @($script:Findings | Sort-Object { Get-Random })
        $plan2 = Build-CopilotTriagePlan -Findings $shuffled -DiffContext 'diff snippet'

        $plan1.PlanHash | Should -Be $plan2.PlanHash
    }

    It 'attaches diff context to each category item' {
        $plan = Build-CopilotTriagePlan -Findings $script:Findings -DiffContext 'DIFF-CONTEXT-123'
        foreach ($item in $plan.Items) {
            $item.DiffContext | Should -Be 'DIFF-CONTEXT-123'
        }
    }

    It 'marks unaddressed Copilot threads and computes AllCopilotThreadsAddressed' {
        $plan = Build-CopilotTriagePlan -Findings $script:Findings -DiffContext ''

        $plan.Summary.AllCopilotThreadsAddressed | Should -BeFalse
        @($plan.Summary.UnaddressedCopilotThreads).Count | Should -Be 2
        @($plan.Summary.UnaddressedCopilotThreads | ForEach-Object { $_.ThreadId }) | Should -Contain 'THREAD_blocker'
        @($plan.Summary.UnaddressedCopilotThreads | ForEach-Object { $_.ThreadId }) | Should -Contain 'THREAD_nit'
    }
}

