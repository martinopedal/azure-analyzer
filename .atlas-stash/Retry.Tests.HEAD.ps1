#Requires -Version 7.4

BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\modules\shared\Retry.ps1')
}

Describe 'Invoke-WithRetry' {
    It 'returns on first success' {
        $script:attempts = 0
        $result = Invoke-WithRetry -ScriptBlock {
            $script:attempts++
            42
        } -BaseDelaySec 0 -MaxDelaySec 0

        $result | Should -Be 42
        $script:attempts | Should -Be 1
    }

    It 'retries retryable failures' {
        $script:attempts = 0
        $result = Invoke-WithRetry -MaxRetries 2 -BaseDelaySec 0 -MaxDelaySec 0 -ScriptBlock {
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
            } -BaseDelaySec 0 -MaxDelaySec 0
        } | Should -Throw

        $script:attempts | Should -Be 1
    }

    It 'throws after max retries' {
        $script:attempts = 0
        {
            Invoke-WithRetry -ScriptBlock {
                $script:attempts++
                $ex = [System.Exception]::new('timeout')
                $ex | Add-Member -NotePropertyName Category -NotePropertyValue 'Timeout'
                throw $ex
            } -MaxRetries 1 -BaseDelaySec 0 -MaxDelaySec 0
        } | Should -Throw

        $script:attempts | Should -Be 2
    }
}
