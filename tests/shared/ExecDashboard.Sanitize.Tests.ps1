#Requires -Version 7.4
Set-StrictMode -Version Latest

Describe 'ExecDashboard disk-write sanitization' {
    BeforeAll {
        $script:RootDir = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        . (Join-Path $script:RootDir 'modules' 'shared' 'RunHistory.ps1')
    }

    It 'removes Bearer tokens before writing dashboard HTML' {
        $token = 'Bearer eyJhbGciOiJIUzI1NiJ9.fake_payload.fake_sig'
        $tmp = Join-Path $TestDrive 'dashboard-sanitize'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $resultsPath = Join-Path $tmp 'results.json'
        @(
            [pscustomobject]@{
                Source     = 'azqr'
                ResourceId = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg/$token/providers/Microsoft.Storage/storageAccounts/sa1"
                Category   = 'Security'
                Title      = "Synthetic token $token"
                Severity   = 'High'
                Compliant  = $false
            }
        ) | ConvertTo-Json -Depth 5 | Set-Content -Path $resultsPath -Encoding UTF8

        $output = Join-Path $tmp 'dashboard.html'
        & (Join-Path $script:RootDir 'New-ExecDashboard.ps1') -InputPath $resultsPath -OutputPath $output | Out-Null

        $html = Get-Content -Path $output -Raw
        $html | Should -Not -Match [regex]::Escape($token)
        $html | Should -Match 'Bearer \[REDACTED\]'
    }
}
