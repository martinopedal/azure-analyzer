#Requires -Version 7.4

BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\modules\shared\Sanitize.ps1')
}

Describe 'Remove-Credentials' {
    It 'redacts ghp tokens' {
        $token = 'ghp_' + ('a' * 36)
        $result = Remove-Credentials "token $token"
        $result | Should -Not -Match [regex]::Escape($token)
        $result | Should -Match '\[GITHUB-PAT-REDACTED\]'
    }

    It 'redacts gho tokens' {
        $token = 'gho_' + ('b' * 36)
        $result = Remove-Credentials "token $token"
        $result | Should -Not -Match [regex]::Escape($token)
        $result | Should -Match '\[GITHUB-OAUTH-REDACTED\]'
    }

    It 'redacts ghs tokens' {
        $token = 'ghs_' + ('c' * 36)
        $result = Remove-Credentials "token $token"
        $result | Should -Not -Match [regex]::Escape($token)
        $result | Should -Match '\[GITHUB-TOKEN-REDACTED\]'
    }

    It 'redacts ghr tokens' {
        $token = 'ghr_' + ('d' * 36)
        $result = Remove-Credentials "token $token"
        $result | Should -Not -Match [regex]::Escape($token)
        $result | Should -Match '\[GITHUB-REFRESH-REDACTED\]'
    }

    It 'redacts fine-grained GitHub PATs' {
        $token = 'github_pat_' + ('e' * 82)
        $result = Remove-Credentials "token $token"
        $result | Should -Not -Match [regex]::Escape($token)
        $result | Should -Match '\[GITHUB-PAT-REDACTED\]'
    }

    It 'redacts ADO PAT basic auth headers' {
        $header = 'Authorization: Basic ' + ('A' * 24)
        $result = Remove-Credentials $header
        $result | Should -Be 'Authorization: [ADO-PAT-REDACTED]'
    }

    It 'redacts Authorization headers' {
        $result = Remove-Credentials 'Authorization: Bearer abc.def'
        $result | Should -Be 'Authorization: [REDACTED]'
    }

    It 'redacts bearer tokens outside headers' {
        $result = Remove-Credentials 'Token: Bearer abcdef123456'
        $result | Should -Be 'Token: Bearer [REDACTED]'
    }

    It 'redacts connection string secrets' {
        $input = 'Endpoint=sb://example;AccountKey=secret;Password=supersecret;'
        $result = Remove-Credentials $input
        $result | Should -Match 'AccountKey=\[REDACTED\]'
        $result | Should -Match 'Password=\[REDACTED\]'
    }

    It 'does not alter normal text' {
        $text = 'Normal text with ghp_1234 and no secrets.'
        Remove-Credentials $text | Should -Be $text
    }
}
