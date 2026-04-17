#Requires -Version 7.4

BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\modules\shared\Retry.ps1')
    . (Join-Path $PSScriptRoot '..\..\modules\shared\Sanitize.ps1')
}

Describe 'Invoke-WithRetry' {
    It 'returns on first success' {
        $script:attempts = 0
        $result = Invoke-WithRetry -ScriptBlock {
            $script:attempts++
            42
        } -InitialDelaySeconds 0 -MaxDelaySeconds 0

        $result | Should -Be 42
        $script:attempts | Should -Be 1
    }

    It 'retries retryable failures' {
        $script:attempts = 0
        $result = Invoke-WithRetry -MaxAttempts 3 -InitialDelaySeconds 0 -MaxDelaySeconds 0 -ScriptBlock {
            $script:attempts++
            if ($script:attempts -lt 3) {
                $ex = [System.Exception]::new('throttled')
                $ex | Add-Member -NotePropertyName Category -NotePropertyValue 'Throttled'
                throw $ex
            }
            return 'ok'
        }

        $result | Should -Be 'ok'
        $script:attempts | Should -Be 3
    }

    It 'fails fast on non-retryable errors' {
        $script:attempts = 0
        {
            Invoke-WithRetry -ScriptBlock {
                $script:attempts++
                $ex = [System.Exception]::new('auth')
                $ex | Add-Member -NotePropertyName Category -NotePropertyValue 'AuthFailed'
                throw $ex
            } -InitialDelaySeconds 0 -MaxDelaySeconds 0
        } | Should -Throw

        $script:attempts | Should -Be 1
    }

    It 'throws after max attempts' {
        $script:attempts = 0
        {
            Invoke-WithRetry -ScriptBlock {
                $script:attempts++
                $ex = [System.Exception]::new('timeout')
                $ex | Add-Member -NotePropertyName Category -NotePropertyValue 'Timeout'
                throw $ex
            } -MaxAttempts 2 -InitialDelaySeconds 0 -MaxDelaySeconds 0
        } | Should -Throw

        $script:attempts | Should -Be 2
    }

    It 'retries on 429 status code' {
        $script:attempts = 0
        
        # Mock Invoke-RestMethod to simulate 429 response
        Mock Invoke-RestMethod {
            $script:attempts++
            if ($script:attempts -lt 2) {
                $response = New-Object PSObject -Property @{
                    StatusCode = 429
                    Headers = @{}
                }
                $ex = New-Object System.Net.Http.HttpRequestException('Too Many Requests')
                Add-Member -InputObject $ex -MemberType NoteProperty -Name Response -Value $response -Force
                throw $ex
            }
            return 'success'
        }

        $result = Invoke-WithRetry -MaxAttempts 3 -InitialDelaySeconds 0 -MaxDelaySeconds 0 -ScriptBlock {
            Invoke-RestMethod -Uri 'http://example.com'
        }

        $result | Should -Be 'success'
        $script:attempts | Should -Be 2
    }

    It 'respects Retry-After header (seconds)' {
        $script:attempts = 0
        $script:sleepSeconds = @()
        
        # Mock Start-Sleep to capture delays
        Mock Start-Sleep {
            param([double]$Seconds)
            $script:sleepSeconds += $Seconds
        }

        Mock Invoke-RestMethod {
            $script:attempts++
            if ($script:attempts -lt 2) {
                # Create a response object with headers
                $headers = @{ 'Retry-After' = '10' }
                $response = New-Object PSObject -Property @{
                    StatusCode = 429
                    Headers = $headers
                }
                
                $ex = New-Object System.Net.Http.HttpRequestException('Too Many Requests')
                Add-Member -InputObject $ex -MemberType NoteProperty -Name Response -Value $response -Force
                throw $ex
            }
            return 'success'
        }

        $result = Invoke-WithRetry -MaxAttempts 3 -InitialDelaySeconds 2 -MaxDelaySeconds 60 -ScriptBlock {
            Invoke-RestMethod -Uri 'http://example.com'
        }

        $result | Should -Be 'success'
        $script:sleepSeconds.Count | Should -Be 1
        $script:sleepSeconds[0] | Should -Be 10
    }

    It 'respects Retry-After header (seconds format)' {
        $script:attempts = 0
        $script:sleepSeconds = @()
        
        # Mock Start-Sleep to capture delays
        Mock Start-Sleep {
            param([double]$Seconds)
            $script:sleepSeconds += $Seconds
        }

        Mock Invoke-RestMethod {
            $script:attempts++
            if ($script:attempts -lt 2) {
                # Create a response object with headers
                $headers = @{ 'Retry-After' = '10' }
                $response = New-Object PSObject -Property @{
                    StatusCode = 429
                    Headers = $headers
                }
                
                $ex = New-Object System.Net.Http.HttpRequestException('Too Many Requests')
                Add-Member -InputObject $ex -MemberType NoteProperty -Name Response -Value $response -Force
                throw $ex
            }
            return 'success'
        }

        $result = Invoke-WithRetry -MaxAttempts 3 -InitialDelaySeconds 2 -MaxDelaySeconds 60 -ScriptBlock {
            Invoke-RestMethod -Uri 'http://example.com'
        }

        $result | Should -Be 'success'
        $script:sleepSeconds.Count | Should -Be 1
        $script:sleepSeconds[0] | Should -Be 10
    }

    It 'falls back to jitter when Retry-After header is invalid' {
        $script:attempts = 0
        $script:sleepSeconds = @()
        
        # Mock Start-Sleep to capture delays
        Mock Start-Sleep {
            param([double]$Seconds)
            $script:sleepSeconds += $Seconds
        }

        Mock Invoke-RestMethod {
            $script:attempts++
            if ($script:attempts -lt 2) {
                # Create a response object with invalid Retry-After
                $headers = @{ 'Retry-After' = 'invalid' }
                $response = New-Object PSObject -Property @{
                    StatusCode = 429
                    Headers = $headers
                }
                
                $ex = New-Object System.Net.Http.HttpRequestException('Too Many Requests')
                Add-Member -InputObject $ex -MemberType NoteProperty -Name Response -Value $response -Force
                throw $ex
            }
            return 'success'
        }

        $result = Invoke-WithRetry -MaxAttempts 3 -InitialDelaySeconds 2 -MaxDelaySeconds 60 -ScriptBlock {
            Invoke-RestMethod -Uri 'http://example.com'
        }

        $result | Should -Be 'success'
        $script:sleepSeconds.Count | Should -Be 1
        # Should use jittered exponential backoff (base 2): between 1.0 and 3.0
        $script:sleepSeconds[0] | Should -BeGreaterOrEqual 1.0
        $script:sleepSeconds[0] | Should -BeLessOrEqual 3.0
    }

    It 'uses exponential backoff with full jitter' {
        $script:attempts = 0
        $script:sleepSeconds = @()
        
        # Mock Start-Sleep to capture delays
        Mock Start-Sleep {
            param($Seconds)
            $script:sleepSeconds += $Seconds
        }

        {
            Invoke-WithRetry -MaxAttempts 4 -InitialDelaySeconds 2 -MaxDelaySeconds 60 -ScriptBlock {
                $script:attempts++
                $ex = [System.Exception]::new('timeout')
                $ex | Add-Member -NotePropertyName Category -NotePropertyValue 'Timeout'
                throw $ex
            }
        } | Should -Throw

        $script:attempts | Should -Be 4
        $script:sleepSeconds.Count | Should -Be 3
        
        # First delay should be between 1.0 (2*0.5) and 3.0 (2*1.5)
        $script:sleepSeconds[0] | Should -BeGreaterOrEqual 1.0
        $script:sleepSeconds[0] | Should -BeLessOrEqual 3.0
        
        # Second delay should be between 2.0 (4*0.5) and 6.0 (4*1.5)
        $script:sleepSeconds[1] | Should -BeGreaterOrEqual 2.0
        $script:sleepSeconds[1] | Should -BeLessOrEqual 6.0
        
        # Third delay should be between 4.0 (8*0.5) and 12.0 (8*1.5)
        $script:sleepSeconds[2] | Should -BeGreaterOrEqual 4.0
        $script:sleepSeconds[2] | Should -BeLessOrEqual 12.0
    }

    It 'throws after MaxAttempts with non-retryable error' {
        $script:attempts = 0
        {
            Invoke-WithRetry -ScriptBlock {
                $script:attempts++
                throw [System.Exception]::new('400 Bad Request')
            } -MaxAttempts 3 -InitialDelaySeconds 0 -MaxDelaySeconds 0
        } | Should -Throw -ExpectedMessage '*Non-retryable*'

        $script:attempts | Should -Be 1
    }

    It 'sanitizes final exception message' {
        $script:attempts = 0
        $error = $null
        try {
            Invoke-WithRetry -ScriptBlock {
                $script:attempts++
                $ex = [System.Exception]::new('Failed with token ghp_1234567890123456789012345678901234567890')
                $ex | Add-Member -NotePropertyName Category -NotePropertyValue 'Timeout'
                throw $ex
            } -MaxAttempts 2 -InitialDelaySeconds 0 -MaxDelaySeconds 0
        } catch {
            $error = $_
        }

        $error | Should -Not -BeNullOrEmpty
        # Exception message should be sanitized (credentials removed by Remove-Credentials)
        $error.Exception.Message | Should -Not -Match 'ghp_123'
        $script:attempts | Should -Be 2
    }

    It 'retries on exception message patterns (429)' {
        $script:attempts = 0
        $result = Invoke-WithRetry -MaxAttempts 3 -InitialDelaySeconds 0 -MaxDelaySeconds 0 -ScriptBlock {
            $script:attempts++
            if ($script:attempts -lt 2) {
                throw [System.Exception]::new('HTTP 429 rate limit exceeded')
            }
            return 'ok'
        }

        $result | Should -Be 'ok'
        $script:attempts | Should -Be 2
    }

    It 'retries on exception message patterns (503)' {
        $script:attempts = 0
        $result = Invoke-WithRetry -MaxAttempts 3 -InitialDelaySeconds 0 -MaxDelaySeconds 0 -ScriptBlock {
            $script:attempts++
            if ($script:attempts -lt 2) {
                throw [System.Exception]::new('Service Unavailable 503')
            }
            return 'ok'
        }

        $result | Should -Be 'ok'
        $script:attempts | Should -Be 2
    }

    It 'writes verbose output on retry attempts' {
        $script:attempts = 0
        $verboseOutput = @()
        
        # Capture verbose output
        $result = Invoke-WithRetry -MaxAttempts 3 -InitialDelaySeconds 0 -MaxDelaySeconds 0 -ScriptBlock {
            $script:attempts++
            if ($script:attempts -lt 2) {
                $ex = [System.Exception]::new('throttled')
                $ex | Add-Member -NotePropertyName Category -NotePropertyValue 'Throttled'
                throw $ex
            }
            return 'ok'
        } -Verbose 4>&1 | Tee-Object -Variable verboseOutput

        $verboseMessages = $verboseOutput | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } | ForEach-Object { $_.Message }
        $verboseMessages | Should -Not -BeNullOrEmpty
        $verboseMessages | Should -Contain 'Invoke-WithRetry: Attempt 1 of 3'
        $verboseMessages | Should -Contain 'Invoke-WithRetry: Attempt 2 of 3'
    }

    It 'supports backward-compatible parameter names (MaxRetries)' {
        $script:attempts = 0
        $result = Invoke-WithRetry -MaxRetries 2 -BaseDelaySec 0 -MaxDelaySec 0 -ScriptBlock {
            $script:attempts++
            if ($script:attempts -lt 2) {
                $ex = [System.Exception]::new('throttled')
                $ex | Add-Member -NotePropertyName Category -NotePropertyValue 'Throttled'
                throw $ex
            }
            return 'ok'
        }

        $result | Should -Be 'ok'
        $script:attempts | Should -Be 2
    }
}
