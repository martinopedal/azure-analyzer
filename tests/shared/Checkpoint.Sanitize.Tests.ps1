#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\..\modules\shared\Checkpoint.ps1"
}

Describe 'Save-Checkpoint disk-write sanitization' {
    It 'removes Bearer tokens from checkpoint JSON written to disk' {
        $token = 'Bearer eyJhbGciOiJIUzI1NiJ9.fake_payload.fake_sig'
        $testDir = Join-Path $TestDrive 'checkpoint-sanitize'

        $result = [PSCustomObject]@{
            Status = 'Complete'
            Detail = "Synthetic token $token"
        }

        $path = Save-Checkpoint -CheckpointDir $testDir -Tool 'test-tool' -ScopeType Subscription -SubscriptionId 'sub-sanitize' -Result $result
        $content = Get-Content -Path $path -Raw

        $content | Should -Not -Match [regex]::Escape($token)
        $content | Should -Match 'Bearer \[REDACTED\]'
    }
}
