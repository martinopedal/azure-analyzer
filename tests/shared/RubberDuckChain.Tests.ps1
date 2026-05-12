#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

<#
.SYNOPSIS
    Pester tests for the RubberDuckChain retry orchestrator.

.DESCRIPTION
    Covers the frontier-only retry + fallback chain used by the
    rubber-duck PR review gate (issue #967).
#>

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
    . (Join-Path $repoRoot 'modules' 'shared' 'Sanitize.ps1')
    . (Join-Path $repoRoot 'modules' 'shared' 'RubberDuckChain.ps1')
}

Describe 'Get-FrontierFallbackChain' {
    It 'returns the frontier-only chain' {
        $chain = Get-FrontierFallbackChain
        $chain | Should -Not -BeNullOrEmpty
        $chain | Should -HaveCount 5
        $chain[0] | Should -Be 'claude-opus-4.7'
        $chain[1] | Should -Be 'claude-opus-4.6-1m'
        $chain[2] | Should -Be 'gpt-5.4'
        $chain[3] | Should -Be 'gpt-5.3-codex'
        $chain[4] | Should -Be 'goldeneye'
    }

    It 'never contains sonnet, haiku, mini, gpt-4.1, or opus-4.6-base' {
        $chain = Get-FrontierFallbackChain
        $banned = @('sonnet', 'haiku', 'mini', 'gpt-4.1', 'opus-4.6-base', 'opus-4.5')
        foreach ($b in $banned) {
            $chain | Where-Object { $_ -like "*$b*" } | Should -BeNullOrEmpty `
                -Because "Frontier chain MUST NOT contain $b (security incident)"
        }
    }
}

Describe 'Get-DefaultRubberDuckTrio' {
    It 'returns the standard 3-model gate trio' {
        $trio = Get-DefaultRubberDuckTrio
        $trio | Should -Not -BeNullOrEmpty
        $trio | Should -HaveCount 3
        $trio[0] | Should -Be 'claude-opus-4.7'
        $trio[1] | Should -Be 'gpt-5.3-codex'
        $trio[2] | Should -Be 'goldeneye'
    }
}

Describe 'Test-RetryableModelError' {
    Context 'HTTP status codes' {
        It 'returns $true for 429' {
            Test-RetryableModelError -StatusCode 429 | Should -BeTrue
        }

        It 'returns $true for 503' {
            Test-RetryableModelError -StatusCode 503 | Should -BeTrue
        }

        It 'returns $true for 504' {
            Test-RetryableModelError -StatusCode 504 | Should -BeTrue
        }

        It 'returns $false for 400' {
            Test-RetryableModelError -StatusCode 400 | Should -BeFalse
        }

        It 'returns $false for 401' {
            Test-RetryableModelError -StatusCode 401 | Should -BeFalse
        }
    }

    Context 'Message patterns' {
        It 'returns $true for rate_limit' {
            Test-RetryableModelError -Message 'rate_limit exceeded' | Should -BeTrue
        }

        It 'returns $true for quota_exceeded' {
            Test-RetryableModelError -Message 'quota_exceeded' | Should -BeTrue
        }

        It 'returns $true for overloaded' {
            Test-RetryableModelError -Message 'Service is overloaded' | Should -BeTrue
        }

        It 'returns $true for temporarily_unavailable' {
            Test-RetryableModelError -Message 'temporarily_unavailable' | Should -BeTrue
        }

        It 'returns $true for service_unavailable' {
            Test-RetryableModelError -Message 'service_unavailable' | Should -BeTrue
        }

        It 'returns $true for throttle' {
            Test-RetryableModelError -Message 'Request was throttled' | Should -BeTrue
        }

        It 'returns $true for socket timeout' {
            Test-RetryableModelError -Message 'socket timeout occurred' | Should -BeTrue
        }

        It 'returns $true for connection reset' {
            Test-RetryableModelError -Message 'connection reset by peer' | Should -BeTrue
        }

        It 'returns $false for non-retryable error' {
            Test-RetryableModelError -Message 'Authentication failed' | Should -BeFalse
        }

        It 'returns $false for empty message' {
            Test-RetryableModelError -Message '' | Should -BeFalse
        }
    }
}

Describe 'Test-ContextOverflowError' {
    It 'returns $true for context_length_exceeded' {
        Test-ContextOverflowError -Message 'context_length_exceeded' | Should -BeTrue
    }

    It 'returns $true for maximum context' {
        Test-ContextOverflowError -Message 'maximum context length exceeded' | Should -BeTrue
    }

    It 'returns $true for too many tokens' {
        Test-ContextOverflowError -Message 'too many tokens in request' | Should -BeTrue
    }

    It 'returns $false for non-overflow error' {
        Test-ContextOverflowError -Message 'rate limit exceeded' | Should -BeFalse
    }

    It 'returns $false for empty message' {
        Test-ContextOverflowError -Message '' | Should -BeFalse
    }
}

Describe 'Get-RetryBackoffSeconds' {
    It 'returns 1s base for attempt 0' {
        $delay = Get-RetryBackoffSeconds -Attempt 0 -BaseSeconds 1.0
        $delay | Should -BeGreaterOrEqual 0.75
        $delay | Should -BeLessOrEqual 1.25
    }

    It 'returns 4s base for attempt 1' {
        $delay = Get-RetryBackoffSeconds -Attempt 1 -BaseSeconds 1.0
        $delay | Should -BeGreaterOrEqual 3.0
        $delay | Should -BeLessOrEqual 5.0
    }

    It 'returns 16s base for attempt 2' {
        $delay = Get-RetryBackoffSeconds -Attempt 2 -BaseSeconds 1.0
        $delay | Should -BeGreaterOrEqual 12.0
        $delay | Should -BeLessOrEqual 20.0
    }

    It 'respects +/-25% jitter bounds' {
        $delays = @()
        for ($i = 0; $i -lt 100; $i++) {
            $delays += Get-RetryBackoffSeconds -Attempt 1 -BaseSeconds 1.0
        }
        $delays | ForEach-Object {
            $_ | Should -BeGreaterOrEqual 3.0
            $_ | Should -BeLessOrEqual 5.0
        }
    }

    It 'never returns negative delay' {
        for ($i = 0; $i -lt 50; $i++) {
            $delay = Get-RetryBackoffSeconds -Attempt 0 -BaseSeconds 1.0
            $delay | Should -BeGreaterOrEqual 0.0
        }
    }
}

Describe 'Invoke-ModelWithRetry' {
    Context 'Success path' {
        It 'returns Success on first attempt' {
            $script:attempts = 0
            $invoker = {
                param($model, $context)
                $script:attempts++
                return @{ verdict = 'approve' }
            }

            $result = Invoke-ModelWithRetry `
                -ModelName 'test-model' `
                -CallContext @{} `
                -CallInvoker $invoker

            $result.Outcome | Should -Be 'Success'
            $result.Model | Should -Be 'test-model'
            $result.Response.verdict | Should -Be 'approve'
            $result.Attempts | Should -Be 1
            $script:attempts | Should -Be 1
        }
    }

    Context 'Retry on transient errors' {
        It 'retries on HTTP 429 and succeeds on 2nd attempt' {
            $script:attempts = 0
            $script:sleepSeconds = @()
            Mock Start-Sleep {
                param([double]$Seconds)
                $script:sleepSeconds += $Seconds
            }

            $invoker = {
                param($model, $context)
                $script:attempts++
                if ($script:attempts -lt 2) {
                    $ex = [System.Exception]::new('HTTP 429 rate limit')
                    $ex | Add-Member -NotePropertyName StatusCode -NotePropertyValue 429 -Force
                    throw $ex
                }
                return @{ verdict = 'approve' }
            }

            $sleep = { param($s) Start-Sleep -Seconds $s }
            $result = Invoke-ModelWithRetry `
                -ModelName 'test-model' `
                -CallContext @{} `
                -CallInvoker $invoker `
                -Sleep $sleep

            $result.Outcome | Should -Be 'Success'
            $result.Attempts | Should -Be 2
            $script:attempts | Should -Be 2
            $script:sleepSeconds.Count | Should -Be 1
            $script:sleepSeconds[0] | Should -BeGreaterOrEqual 0.75
            $script:sleepSeconds[0] | Should -BeLessOrEqual 1.25
        }

        It 'gives up after 3 failed attempts and returns Exhausted' {
            $script:attempts = 0
            $script:sleepSeconds = @()
            Mock Start-Sleep {
                param([double]$Seconds)
                $script:sleepSeconds += $Seconds
            }

            $invoker = {
                param($model, $context)
                $script:attempts++
                $ex = [System.Exception]::new('HTTP 503 service unavailable')
                throw $ex
            }

            $sleep = { param($s) Start-Sleep -Seconds $s }
            $result = Invoke-ModelWithRetry `
                -ModelName 'test-model' `
                -CallContext @{} `
                -CallInvoker $invoker `
                -Sleep $sleep

            $result.Outcome | Should -Be 'Exhausted'
            $result.Model | Should -Be 'test-model'
            $result.Attempts | Should -Be 3
            $script:attempts | Should -Be 3
            $script:sleepSeconds.Count | Should -Be 2
        }
    }

    Context 'Exponential backoff with jitter' {
        It 'respects 1s -> 4s -> 16s pattern with +/-25% jitter' {
            $script:attempts = 0
            $script:sleepSeconds = @()
            Mock Start-Sleep {
                param([double]$Seconds)
                $script:sleepSeconds += $Seconds
            }

            $invoker = {
                param($model, $context)
                $script:attempts++
                $ex = [System.Exception]::new('throttled')
                throw $ex
            }

            $sleep = { param($s) Start-Sleep -Seconds $s }
            $result = Invoke-ModelWithRetry `
                -ModelName 'test-model' `
                -CallContext @{} `
                -CallInvoker $invoker `
                -Sleep $sleep

            $script:sleepSeconds.Count | Should -Be 2
            $script:sleepSeconds[0] | Should -BeGreaterOrEqual 0.75
            $script:sleepSeconds[0] | Should -BeLessOrEqual 1.25
            $script:sleepSeconds[1] | Should -BeGreaterOrEqual 3.0
            $script:sleepSeconds[1] | Should -BeLessOrEqual 5.0
        }
    }

    Context 'Context overflow short-circuit' {
        It 'returns ContextOverflow immediately on context_length_exceeded' {
            $script:attempts = 0
            $script:sleepSeconds = @()
            Mock Start-Sleep {
                param([double]$Seconds)
                $script:sleepSeconds += $Seconds
            }

            $invoker = {
                param($model, $context)
                $script:attempts++
                throw [System.Exception]::new('context_length_exceeded')
            }

            $sleep = { param($s) Start-Sleep -Seconds $s }
            $result = Invoke-ModelWithRetry `
                -ModelName 'test-model' `
                -CallContext @{} `
                -CallInvoker $invoker `
                -Sleep $sleep

            $result.Outcome | Should -Be 'ContextOverflow'
            $result.Model | Should -Be 'test-model'
            $result.Attempts | Should -Be 1
            $script:attempts | Should -Be 1
            $script:sleepSeconds.Count | Should -Be 0
        }
    }

    Context 'Non-retryable errors' {
        It 'returns Fatal immediately on non-retryable error' {
            $script:attempts = 0
            $script:sleepSeconds = @()
            Mock Start-Sleep {
                param([double]$Seconds)
                $script:sleepSeconds += $Seconds
            }

            $invoker = {
                param($model, $context)
                $script:attempts++
                throw [System.Exception]::new('Authentication failed')
            }

            $sleep = { param($s) Start-Sleep -Seconds $s }
            $result = Invoke-ModelWithRetry `
                -ModelName 'test-model' `
                -CallContext @{} `
                -CallInvoker $invoker `
                -Sleep $sleep

            $result.Outcome | Should -Be 'Fatal'
            $result.Model | Should -Be 'test-model'
            $result.Attempts | Should -Be 1
            $script:attempts | Should -Be 1
            $script:sleepSeconds.Count | Should -Be 0
        }
    }

    Context 'Error message sanitization' {
        It 'sanitizes credentials in error messages' {
            $invoker = {
                throw [System.Exception]::new('Failed with token ghp_1234567890123456789012345678901234567890')
            }

            $result = Invoke-ModelWithRetry `
                -ModelName 'test-model' `
                -CallContext @{} `
                -CallInvoker $invoker

            $result.Outcome | Should -Be 'Fatal'
            $result.Error | Should -Not -Match 'ghp_123'
            $result.Error | Should -Match 'REDACTED'
        }
    }
}

Describe 'Write-FallbackAudit' {
    It 'writes audit row to specified output path' {
        $outputPath = Join-Path $TestDrive 'audit-test'
        $file = Write-FallbackAudit `
            -PRNumber 123 `
            -HeadSha 'abc123def456' `
            -FromModel 'claude-opus-4.7' `
            -ToModel 'gpt-5.4' `
            -Reason 'Exhausted' `
            -OutputPath $outputPath

        $file | Should -Not -BeNullOrEmpty
        Test-Path $file | Should -BeTrue
        $content = Get-Content $file -Raw
        $content | Should -Match 'PR: #123'
        $content | Should -Match 'Head SHA: abc123def456'
        $content | Should -Match 'From model: claude-opus-4.7'
        $content | Should -Match 'To model: gpt-5.4'
        $content | Should -Match 'Reason: Exhausted'
    }

    It 'respects -DryRun and writes nothing' {
        $outputPath = Join-Path $TestDrive 'audit-dryrun'
        $file = Write-FallbackAudit `
            -PRNumber 123 `
            -HeadSha 'abc123' `
            -FromModel 'test-model' `
            -Reason 'test' `
            -OutputPath $outputPath `
            -DryRun

        $file | Should -BeNullOrEmpty
    }

    It 'sanitizes unsafe characters in filenames' {
        $outputPath = Join-Path $TestDrive 'audit-sanitize'
        $file = Write-FallbackAudit `
            -PRNumber 123 `
            -HeadSha 'abc/123\def' `
            -FromModel 'model:with:colons' `
            -ToModel 'model/with/slashes' `
            -Reason 'reason with spaces and !@#$%' `
            -OutputPath $outputPath

        $file | Should -Not -BeNullOrEmpty
        Test-Path $file | Should -BeTrue
        $fileName = [System.IO.Path]::GetFileName($file)
        $fileName | Should -Not -Match '[\\/:]'
    }

    It 'sanitizes credentials in audit body' {
        $outputPath = Join-Path $TestDrive 'audit-credentials'
        $file = Write-FallbackAudit `
            -PRNumber 123 `
            -HeadSha 'abc123' `
            -FromModel 'test-model' `
            -Reason 'Failed with AccountKey=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==' `
            -OutputPath $outputPath

        $file | Should -Not -BeNullOrEmpty
        $content = Get-Content $file -Raw
        $content | Should -Not -Match 'AccountKey=AAAA'
        $content | Should -Match '\[REDACTED'
    }
}

Describe 'Format-ChainExhaustedComment' {
    It 'includes PR number and swap count' {
        $comment = Format-ChainExhaustedComment -PRNumber 123 -Swaps 5
        $comment | Should -Match 'PR #123'
        $comment | Should -Match '5 swaps'
    }

    It 'includes head SHA if provided' {
        $comment = Format-ChainExhaustedComment -PRNumber 123 -HeadSha 'abc123def456'
        $comment | Should -Match 'abc123def456'
    }

    It 'omits SHA line if not provided' {
        $comment = Format-ChainExhaustedComment -PRNumber 123
        $comment | Should -Not -Match 'Head SHA'
    }

    It 'includes the frontier fallback chain' {
        $comment = Format-ChainExhaustedComment -PRNumber 123
        $comment | Should -Match 'claude-opus-4.7'
        $comment | Should -Match 'claude-opus-4.6-1m'
        $comment | Should -Match 'gpt-5.4'
        $comment | Should -Match 'gpt-5.3-codex'
        $comment | Should -Match 'goldeneye'
    }
}

Describe 'Get-NextChainCandidate' {
    It 'returns first chain entry when UsedModels is empty' {
        $chain = @('model-a', 'model-b', 'model-c')
        $used = [System.Collections.Generic.HashSet[string]]::new()
        $next = Get-NextChainCandidate -Chain $chain -UsedModels $used
        $next | Should -Be 'model-a'
    }

    It 'skips used models' {
        $chain = @('model-a', 'model-b', 'model-c')
        $used = [System.Collections.Generic.HashSet[string]]::new()
        [void]$used.Add('model-a')
        $next = Get-NextChainCandidate -Chain $chain -UsedModels $used
        $next | Should -Be 'model-b'
    }

    It 'skips tried-and-failed models' {
        $chain = @('model-a', 'model-b', 'model-c')
        $used = [System.Collections.Generic.HashSet[string]]::new()
        $failed = [System.Collections.Generic.HashSet[string]]::new()
        [void]$failed.Add('model-a')
        [void]$failed.Add('model-b')
        $next = Get-NextChainCandidate -Chain $chain -UsedModels $used -TriedAndFailed $failed
        $next | Should -Be 'model-c'
    }

    It 'returns empty string when all candidates exhausted' {
        $chain = @('model-a', 'model-b')
        $used = [System.Collections.Generic.HashSet[string]]::new()
        [void]$used.Add('model-a')
        [void]$used.Add('model-b')
        $next = Get-NextChainCandidate -Chain $chain -UsedModels $used
        $next | Should -Be ''
    }

    It 'skips the Failed model' {
        $chain = @('model-a', 'model-b', 'model-c')
        $used = [System.Collections.Generic.HashSet[string]]::new()
        $next = Get-NextChainCandidate -Chain $chain -UsedModels $used -Failed 'model-a'
        $next | Should -Be 'model-b'
    }
}

Describe 'Invoke-RubberDuckTrio' {
    Context 'Success path' {
        It 'starts with the standard frontier trio' {
            $script:invokedModels = @()
            $invoker = {
                param($model, $context)
                $script:invokedModels += $model
                return @{ verdict = 'approve' }
            }

            $result = Invoke-RubberDuckTrio `
                -PRNumber 123 `
                -HeadSha 'abc123' `
                -CallContext @{} `
                -CallInvoker $invoker `
                -OutputPath (Join-Path $TestDrive 'trio-audit') `
                -DryRun

            $result.Outcome | Should -Be 'Success'
            $result.Verdicts.Count | Should -Be 3
            $script:invokedModels | Should -Contain 'claude-opus-4.7'
            $script:invokedModels | Should -Contain 'gpt-5.3-codex'
            $script:invokedModels | Should -Contain 'goldeneye'
        }

        It 'never re-invokes a model that already returned a verdict' {
            $script:invokedModels = @()
            $invoker = {
                param($model, $context)
                $script:invokedModels += $model
                return @{ verdict = 'approve' }
            }

            $result = Invoke-RubberDuckTrio `
                -PRNumber 123 `
                -HeadSha 'abc123' `
                -CallContext @{} `
                -CallInvoker $invoker `
                -OutputPath (Join-Path $TestDrive 'trio-distinct') `
                -DryRun

            $result.Outcome | Should -Be 'Success'
            $result.Verdicts.Count | Should -Be 3
            $result.UsedModels.Count | Should -Be 3
            $distinct = $script:invokedModels | Select-Object -Unique
            $distinct.Count | Should -Be $script:invokedModels.Count `
                -Because 'Models that returned verdicts MUST NOT be re-invoked'
        }
    }

    Context 'Model swap on failure' {
        It 'swaps to first eligible chain entry on failure' {
            $script:invokedModels = @()
            $script:modelAttempts = @{}
            $invoker = {
                param($model, $context)
                $script:invokedModels += $model
                if (-not $script:modelAttempts.ContainsKey($model)) {
                    $script:modelAttempts[$model] = 0
                }
                $script:modelAttempts[$model]++
                if ($model -eq 'claude-opus-4.7') {
                    throw [System.Exception]::new('rate limit exceeded')
                }
                return @{ verdict = 'approve' }
            }

            $result = Invoke-RubberDuckTrio `
                -PRNumber 123 `
                -HeadSha 'abc123' `
                -CallContext @{} `
                -CallInvoker $invoker `
                -OutputPath (Join-Path $TestDrive 'trio-swap') `
                -DryRun

            $result.Outcome | Should -Be 'Success'
            $result.Swaps | Should -BeGreaterOrEqual 1
            $script:modelAttempts['claude-opus-4.7'] | Should -Be 3
            $script:invokedModels | Should -Contain 'claude-opus-4.6-1m'
        }

        It 'writes audit row for every swap' {
            $script:modelAttempts = @{}
            $invoker = {
                param($model, $context)
                if (-not $script:modelAttempts.ContainsKey($model)) {
                    $script:modelAttempts[$model] = 0
                }
                $script:modelAttempts[$model]++
                if ($model -eq 'claude-opus-4.7') {
                    throw [System.Exception]::new('throttled')
                }
                return @{ verdict = 'approve' }
            }

            $auditPath = Join-Path $TestDrive 'trio-audit-rows'
            $result = Invoke-RubberDuckTrio `
                -PRNumber 123 `
                -HeadSha 'abc123def456' `
                -CallContext @{} `
                -CallInvoker $invoker `
                -OutputPath $auditPath

            $result.Swaps | Should -BeGreaterOrEqual 1
            $auditFiles = @(Get-ChildItem $auditPath -Filter 'gate-fallback-*.md' -ErrorAction SilentlyContinue)
            $auditFiles.Count | Should -BeGreaterOrEqual 1
            $content = Get-Content $auditFiles[0].FullName -Raw
            $content | Should -Match 'PR: #123'
            $content | Should -Match 'Head SHA: abc123def456'
        }
    }

    Context 'Swap limit enforcement' {
        It 'enforces 5-swap-per-call ceiling and returns SwapLimitExceeded' {
            $script:attemptCount = 0
            $invoker = {
                param($model, $context)
                $script:attemptCount++
                throw [System.Exception]::new('always fail')
            }

            $largeChain = @('m1', 'm2', 'm3', 'm4', 'm5', 'm6', 'm7', 'm8', 'm9', 'm10')
            $largeTrio = @('m1', 'm2', 'm3')

            $result = Invoke-RubberDuckTrio `
                -PRNumber 123 `
                -HeadSha 'abc123' `
                -CallContext @{} `
                -CallInvoker $invoker `
                -OutputPath (Join-Path $TestDrive 'trio-swaplimit') `
                -MaxSwaps 5 `
                -Trio $largeTrio `
                -Chain $largeChain `
                -DryRun

            $result.Outcome | Should -Be 'SwapLimitExceeded'
            $result.Swaps | Should -BeGreaterThan 5
        }
    }

    Context 'Chain exhaustion' {
        It 'returns ChainExhausted when all chain entries fail' {
            $script:attemptCount = 0
            $invoker = {
                param($model, $context)
                $script:attemptCount++
                throw [System.Exception]::new('all fail')
            }

            $result = Invoke-RubberDuckTrio `
                -PRNumber 123 `
                -HeadSha 'abc123' `
                -CallContext @{} `
                -CallInvoker $invoker `
                -OutputPath (Join-Path $TestDrive 'trio-exhausted') `
                -MaxSwaps 50 `
                -DryRun

            $result.Outcome | Should -Be 'ChainExhausted'
            $result.Verdicts.Count | Should -BeLessThan 3
        }
    }

    Context 'Context overflow immediate swap' {
        It 'short-circuits retry on context_length_exceeded' {
            $script:invokedModels = @()
            $script:attemptCounts = @{}
            $invoker = {
                param($model, $context)
                $script:invokedModels += $model
                if (-not $script:attemptCounts.ContainsKey($model)) {
                    $script:attemptCounts[$model] = 0
                }
                $script:attemptCounts[$model]++
                if ($model -eq 'claude-opus-4.7') {
                    throw [System.Exception]::new('context_length_exceeded')
                }
                return @{ verdict = 'approve' }
            }

            $result = Invoke-RubberDuckTrio `
                -PRNumber 123 `
                -HeadSha 'abc123' `
                -CallContext @{} `
                -CallInvoker $invoker `
                -OutputPath (Join-Path $TestDrive 'trio-context-overflow') `
                -DryRun

            $result.Outcome | Should -Be 'Success'
            $result.Swaps | Should -Be 1
            $script:attemptCounts['claude-opus-4.7'] | Should -Be 1
            $script:invokedModels | Should -Contain 'claude-opus-4.6-1m'
        }
    }
}
