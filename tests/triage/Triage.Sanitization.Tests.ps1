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
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Args)
            $cmd = ($Args -join ' ')
            $global:LASTEXITCODE = 0
            if ($cmd -eq 'copilot models list --json id') { return '[{"id":"claude-sonnet-4.6"},{"id":"gpt-5.2"},{"id":"gemini-3-pro-preview"}]' }
            throw "unexpected gh call: $cmd"
        }
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

    Context 'Extended credential patterns (round-2 bottom-fix)' {
        It 'redacts gho_ OAuth tokens' {
            $t = 'gho_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij'
            (Remove-Credentials "auth=$t") | Should -Match '\[GITHUB-OAUTH-REDACTED\]'
        }
        It 'redacts ghs_ session tokens' {
            $t = 'ghs_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij'
            (Remove-Credentials "auth=$t") | Should -Match '\[GITHUB-TOKEN-REDACTED\]'
        }
        It 'redacts ghr_ refresh tokens' {
            $t = 'ghr_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij'
            (Remove-Credentials "auth=$t") | Should -Match '\[GITHUB-REFRESH-REDACTED\]'
        }
        It 'redacts github_pat_ fine-grained tokens' {
            $body = ('A' * 82)
            $t = "github_pat_$body"
            (Remove-Credentials "auth=$t") | Should -Match '\[GITHUB-PAT-REDACTED\]'
        }
        It 'redacts JWT bearer payloads' {
            $jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NSJ9.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U'
            $out = Remove-Credentials "token: $jwt"
            $out | Should -Match '\[JWT-REDACTED\]'
            $out | Should -Not -Match $jwt
        }
        It 'redacts Bearer tokens' {
            $out = Remove-Credentials 'Bearer abc.def.ghi-jkl_mn'
            $out | Should -Match 'Bearer \[REDACTED\]'
        }
        It 'redacts Azure Storage AccountKey in connection strings' {
            $cs = 'DefaultEndpointsProtocol=https;AccountName=foo;AccountKey=AAAAbbbbCCCCddddEEEEffffGGGGhhhh==;EndpointSuffix=core.windows.net'
            $out = Remove-Credentials $cs
            $out | Should -Match 'AccountKey=\[REDACTED\]'
            $out | Should -Not -Match 'AAAAbbbbCCCCdddd'
        }
        It 'redacts SAS sig= and sv= query params' {
            $sas = 'https://foo.blob.core.windows.net/c/b?sv=2023-11-03&sig=abcdefghijKLMNOPqrstuvwxyz123456789%2Babc%3D'
            $out = Remove-Credentials $sas
            $out | Should -Match 'sig=\[REDACTED\]'
            $out | Should -Match 'sv=\[REDACTED\]'
        }
        It 'redacts client_secret query params' {
            $out = Remove-Credentials 'POST /token client_secret=ABCDEFG-very-secret-value&grant_type=client_credentials'
            $out | Should -Match 'client_secret=\[REDACTED\]'
        }
        It 'redacts OpenAI sk- keys' {
            $out = Remove-Credentials 'OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz0123'
            $out | Should -Match '\[OPENAI-KEY-REDACTED\]'
        }
        It 'redacts OpenAI sk-proj- keys' {
            $out = Remove-Credentials 'key: sk-proj-abcdefghijklmnopqrstuvwxyz012345'
            $out | Should -Match '\[OPENAI-KEY-REDACTED\]'
        }
        It 'redacts Slack xoxb- bot tokens' {
            $out = Remove-Credentials 'slack=xoxb-1234567890-abcdefghij'
            $out | Should -Match '\[SLACK-TOKEN-REDACTED\]'
        }
        It 'redacts AZURE_OPENAI_API_KEY env-style assignment' {
            $out = Remove-Credentials 'AZURE_OPENAI_API_KEY=abcdef1234567890XYZ'
            $out | Should -Match 'AZURE_OPENAI_API_KEY=\[REDACTED\]'
        }
        It 'preserves bare GUIDs (negative case)' {
            $g = '11111111-2222-3333-4444-555555555555'
            (Remove-Credentials "subscription=$g") | Should -Match $g
        }
        It 'preserves non-ASCII text pass-through' {
            $s = 'finding: kaeyk teken niet redactie compleet 漢字 émoji 🎉'
            (Remove-Credentials $s) | Should -Be $s
        }
    }
}
