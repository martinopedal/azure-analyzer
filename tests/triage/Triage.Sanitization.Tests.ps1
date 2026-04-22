#requires -Version 7.4
#requires -Modules Pester

Set-StrictMode -Version Latest

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' '..' 'modules' 'shared' 'Triage' 'Invoke-CopilotTriage.ps1'
    . $script:ModulePath
}

Describe 'LLM triage sanitization (#433)' {
    It 'sanitizes prompt secrets before prompt use' {
        $sanitized = Invoke-PromptSanitization -Prompt 'token=ghp_123456789012345678901234567890123456'
        $sanitized | Should -Not -Match 'ghp_123456789012345678901234567890123456'
        $sanitized | Should -Match '\[GITHUB-PAT-REDACTED\]'
    }

    It 'sanitizes echoed response secrets' {
        $secret = 'ghp_123456789012345678901234567890123456'
        $sanitized = Invoke-ResponseSanitization -Response "echo: $secret"
        $sanitized | Should -Not -Match $secret
        $sanitized | Should -Match '\[GITHUB-PAT-REDACTED\]'
    }

    It 'preserves canonical entity IDs while sanitizing prompt content' {
        $input = 'entity=tenant:11111111-1111-1111-1111-111111111111 token=ghp_123456789012345678901234567890123456'
        $sanitized = Invoke-PromptSanitization -Prompt $input
        $sanitized | Should -Match 'tenant:11111111-1111-1111-1111-111111111111'
        $sanitized | Should -Not -Match 'ghp_123456789012345678901234567890123456'
    }

    It 'enforces end-to-end sanitization in Invoke-CopilotTriage output fields' {
        function global:gh { throw 'unsupported command' }
        try {
            $secret = 'ghp_123456789012345678901234567890123456'
            $finding = [pscustomobject]@{
                Id    = 'f1'
                Title = "poisoned-$secret"
            }

            $result = Invoke-CopilotTriage `
                -Findings @($finding) `
                -CopilotTier Pro `
                -SingleModel `
                -MockModelResponse "model echoed $secret"

            $result.Prompt | Should -Not -Match $secret
            $result.Response | Should -Not -Match $secret
            $result.Prompt | Should -Match '\[GITHUB-PAT-REDACTED\]'
            $result.Response | Should -Match '\[GITHUB-PAT-REDACTED\]'
        } finally {
            Remove-Item Function:\global:gh -ErrorAction SilentlyContinue
        }
    }
}
