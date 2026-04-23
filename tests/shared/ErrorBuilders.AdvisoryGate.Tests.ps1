#Requires -Version 7.4
# Tests for issue #743 -- the Copilot triage plan validation in
# Invoke-PRAdvisoryGate.ps1 now routes raw throws through New-FindingError.

Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Sanitize.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Errors.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Invoke-PRAdvisoryGate.ps1')
}

Describe 'shared:Invoke-PRAdvisoryGate routes Copilot triage plan errors through New-FindingError (#743)' {
    It 'throws a structured NotFound error when the plan file is missing' {
        $missing = Join-Path ([System.IO.Path]::GetTempPath()) ("missing-" + [guid]::NewGuid().ToString('N') + '.json')
        { Import-CopilotTriagePlan -PlanPath $missing } |
            Should -Throw -ExpectedMessage '*`[shared:Invoke-PRAdvisoryGate] NotFound:*Copilot triage plan file not found*'
    }

    It 'throws a structured ConfigurationError when the plan file is empty' {
        $emptyPath = Join-Path ([System.IO.Path]::GetTempPath()) ("empty-" + [guid]::NewGuid().ToString('N') + '.json')
        try {
            New-Item -Path $emptyPath -ItemType File -Force | Out-Null
            { Import-CopilotTriagePlan -PlanPath $emptyPath } |
                Should -Throw -ExpectedMessage '*`[shared:Invoke-PRAdvisoryGate] ConfigurationError:*Copilot triage plan file is empty*'
        } finally {
            Remove-Item -Path $emptyPath -ErrorAction SilentlyContinue
        }
    }
}
