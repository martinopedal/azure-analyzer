#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Sanitize.ps1')
}

Describe 'Invoke-AzureCost: Set-Content uses Remove-Credentials' {
    It 'the wrapper source wraps Set-Content output through Remove-Credentials' {
        $source = Get-Content (Join-Path $script:RepoRoot 'modules' 'Invoke-AzureCost.ps1') -Raw
        # The output-write block must call Remove-Credentials before/around Set-Content
        $source | Should -Match 'Remove-Credentials.*\$result.*ConvertTo-Json.*Set-Content'
    }
}

Describe 'Invoke-DefenderForCloud: Set-Content uses Remove-Credentials' {
    It 'the wrapper source wraps Set-Content output through Remove-Credentials' {
        $source = Get-Content (Join-Path $script:RepoRoot 'modules' 'Invoke-DefenderForCloud.ps1') -Raw
        $source | Should -Match 'Remove-Credentials.*\$result.*ConvertTo-Json.*Set-Content'
    }
}

Describe 'Invoke-SentinelIncidents: Set-Content uses Remove-Credentials' {
    It 'the wrapper source wraps Set-Content output through Remove-Credentials' {
        $source = Get-Content (Join-Path $script:RepoRoot 'modules' 'Invoke-SentinelIncidents.ps1') -Raw
        $source | Should -Match 'Remove-Credentials.*\$result.*ConvertTo-Json.*Set-Content'
    }
}

Describe 'Remove-Credentials integration: Bearer token in JSON is sanitized' {
    It 'strips Bearer token from a JSON payload that would be written to disk' {
        $payload = @{
            Status   = 'Complete'
            Message  = 'Bearer eyJfake.token.value leaked here'
            Findings = @(@{
                Title = 'Some finding with Bearer eyJfake.token.value'
            })
        }
        $json = $payload | ConvertTo-Json -Depth 20
        $sanitized = Remove-Credentials $json

        $sanitized | Should -Not -Match 'eyJfake\.token\.value'
        $sanitized | Should -Match '\[REDACTED\]'
    }
}
