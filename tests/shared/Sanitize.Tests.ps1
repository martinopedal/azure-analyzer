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

Describe 'Error Message Sanitization (Disk Write Scenarios)' {
    It 'sanitizes SAS URI in exception message before disk write' {
        $testDir = Join-Path $TestDrive 'error-test'
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        
        $errorMsg = 'Failed to connect to https://mystorageacct.blob.core.windows.net/container?sig=AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJKKKK&se=2026-01-01'
        $sanitized = Remove-Credentials $errorMsg
        $outputFile = Join-Path $testDir 'error.json'
        
        @{ tool = 'test-tool'; error = $sanitized } | ConvertTo-Json | Set-Content $outputFile
        $diskContent = Get-Content $outputFile -Raw
        
        $diskContent | Should -Not -Match 'sig=AAAA'
        $diskContent | Should -Match '\[REDACTED\]'
    }
    
    It 'sanitizes bearer token in exception message before disk write' {
        $testDir = Join-Path $TestDrive 'bearer-test'
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        
        $errorMsg = 'Authorization failed: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0'
        $sanitized = Remove-Credentials $errorMsg
        $outputFile = Join-Path $testDir 'auth-error.txt'
        
        $sanitized | Set-Content $outputFile
        $diskContent = Get-Content $outputFile -Raw
        
        $diskContent | Should -Not -Match 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9'
        $diskContent | Should -Match 'Bearer \[REDACTED\]'
    }
    
    It 'sanitizes Azure subscription connection string in exception message' {
        $errorMsg = 'Connection failed: Endpoint=sb://mybus.servicebus.windows.net/;SharedAccessKey=secretkey123456789abcdefghij;EntityPath=myqueue'
        $sanitized = Remove-Credentials $errorMsg
        
        $sanitized | Should -Not -Match 'secretkey123456789'
        $sanitized | Should -Match 'SharedAccessKey=\[REDACTED\]'
    }
    
    It 'sanitizes GitHub PAT in exception message before JSON write' {
        $testDir = Join-Path $TestDrive 'github-test'
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null
        
        $token = 'ghp_' + ('a' * 36)
        $errorMsg = "GitHub API call failed with token $token"
        $sanitized = Remove-Credentials $errorMsg
        $outputFile = Join-Path $testDir 'github-error.json'
        
        @{ source = 'github-tool'; status = 'Failed'; message = $sanitized } | ConvertTo-Json | Set-Content $outputFile
        $diskContent = Get-Content $outputFile -Raw
        
        $diskContent | Should -Not -Match $token
        $diskContent | Should -Match '\[GITHUB-PAT-REDACTED\]'
    }
    
    It 'handles null or empty error messages gracefully' {
        $sanitized1 = Remove-Credentials $null
        $sanitized2 = Remove-Credentials ''
        
        $sanitized1 | Should -BeNullOrEmpty
        $sanitized2 | Should -Be ''
    }
    
    It 'sanitizes multiple secrets in single error message' {
        $errorMsg = 'Multi-auth failed: Authorization: Bearer abc123def456 and AccountKey=supersecret123; also failed SAS query https://storage.blob.core.windows.net/?sig=AAABBBCCCDDDEEEFFF12345%2B%2Fabc'
        $sanitized = Remove-Credentials $errorMsg
        
        $sanitized | Should -Not -Match 'abc123def456'
        $sanitized | Should -Not -Match 'supersecret123'
        $sanitized | Should -Not -Match 'sig=AAABBBCCCDDDEEEFFF'
        $sanitized | Should -Match 'Authorization: \[REDACTED\]'
        $sanitized | Should -Match 'AccountKey=\[REDACTED\]'
        $sanitized | Should -Match 'sig=\[REDACTED\]'
    }

    It 'blocks poisoned Password field across JSON CSV SARIF and manifest sidecars' {
        $dir = Join-Path $TestDrive 'sanitize-parity'
        $null = New-Item -ItemType Directory -Path $dir -Force

        $json = Remove-Credentials '{"tool":"x","Password":"secret123"}'
        $csv = Remove-Credentials "key,value`nPassword,secret123"
        $sarif = Remove-Credentials '{"runs":[{"results":[{"message":{"text":"Password=secret123"}}]}]}'
        $manifest = Remove-Credentials '{"SchemaVersion":"1.0","notes":"Password=secret123"}'

        Set-Content -Path (Join-Path $dir 'chunk-findings-1.json') -Value $json -Encoding UTF8
        Set-Content -Path (Join-Path $dir 'results.csv') -Value $csv -Encoding UTF8
        Set-Content -Path (Join-Path $dir 'results.sarif') -Value $sarif -Encoding UTF8
        Set-Content -Path (Join-Path $dir 'report-manifest.json') -Value $manifest -Encoding UTF8

        foreach ($file in @('chunk-findings-1.json', 'results.csv', 'results.sarif', 'report-manifest.json')) {
            $content = Get-Content -Path (Join-Path $dir $file) -Raw
            $content | Should -Not -Match 'Password=secret123'
            $content | Should -Not -Match '"Password":"secret123"'
            $content | Should -Not -Match 'Password,secret123'
        }
    }
}

