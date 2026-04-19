#Requires -Version 7.4
Set-StrictMode -Version Latest

Describe 'ExecDashboard sanitizes HTML before Set-Content' {
    BeforeAll {
        $script:RootDir = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        . (Join-Path $RootDir 'modules' 'shared' 'Sanitize.ps1')
        . (Join-Path $RootDir 'modules' 'shared' 'RunHistory.ps1')
    }

    It 'strips Bearer tokens from dashboard HTML via Remove-Credentials' {
        $tmp = Join-Path $TestDrive 'dashboard-sanitize'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $resultsPath = Join-Path $tmp 'results.json'

        # Inject a Bearer token into the Title field of a finding
        $sub = '11111111-1111-1111-1111-111111111111'
        $findings = @([pscustomobject]@{
            Source      = 'azqr'
            ResourceId  = "/subscriptions/$sub/rg/a/storage/x"
            Category    = 'Security'
            Title       = 'Bearer eyJfake.token.value'
            Severity    = 'High'
            Compliant   = $false
            Detail      = 'Bearer eyJfake.token.value in detail'
            Remediation = 'Bearer eyJfake.token.value in remediation'
        })
        $findings | ConvertTo-Json -Depth 5 | Set-Content -Path $resultsPath -Encoding UTF8

        $output = Join-Path $tmp 'dashboard.html'

        & (Join-Path $RootDir 'New-ExecDashboard.ps1') -InputPath $resultsPath -OutputPath $output | Out-Null

        Test-Path $output | Should -BeTrue
        $content = Get-Content $output -Raw
        # The token must NOT survive to disk — Remove-Credentials strips it
        $content | Should -Not -Match 'eyJfake\.token\.value'
    }
}
