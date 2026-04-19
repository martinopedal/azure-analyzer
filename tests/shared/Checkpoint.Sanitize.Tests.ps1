#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\..\modules\shared\Sanitize.ps1"
    . "$PSScriptRoot\..\..\modules\shared\Checkpoint.ps1"
}

Describe 'Save-Checkpoint sanitizes JSON before writing' {
    It 'strips credentials from checkpoint data before Set-Content' {
        $testDir = Join-Path $TestDrive 'checkpoint-sanitize'

        $result = [PSCustomObject]@{
            Status = 'Complete'
            Detail = 'Bearer eyJfake.token.value'
        }

        $path = Save-Checkpoint -CheckpointDir $testDir -Tool 'test-tool' `
            -ScopeType Subscription -SubscriptionId 'sub-sanitize' -Result $result

        $path | Should -Not -BeNullOrEmpty
        Test-Path $path | Should -BeTrue

        $content = Get-Content $path -Raw
        $content | Should -Not -Match 'eyJfake\.token\.value'
        $content | Should -Match '\[REDACTED\]'
    }
}
