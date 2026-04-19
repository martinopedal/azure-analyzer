#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Sanitize.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Retry.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'sinks' 'Send-FindingsToLogAnalytics.ps1')

    $script:FixtureDir = Join-Path $script:RepoRoot 'tests' 'fixtures' 'sinks'
}

Describe 'Send-FindingsToLogAnalytics' {
    It 'throws when EntitiesJson path does not exist' {
        {
            Send-FindingsToLogAnalytics `
                -EntitiesJson (Join-Path $TestDrive 'missing.json') `
                -DceEndpoint 'https://example.eastus-1.ingest.monitor.azure.com' `
                -DcrImmutableId 'dcr-123' `
                -StreamName 'Custom-AzureAnalyzerFindings'
        } | Should -Throw '*not found*'
    }

    It 'throws when DceEndpoint is missing' {
        {
            Send-FindingsToLogAnalytics `
                -EntitiesJson (Join-Path $script:FixtureDir 'entities-1.json') `
                -DceEndpoint '' `
                -DcrImmutableId 'dcr-123' `
                -StreamName 'Custom-AzureAnalyzerFindings'
        } | Should -Throw '*empty string*'
    }

    It 'throws when DceEndpoint is not HTTPS' {
        {
            Send-FindingsToLogAnalytics `
                -EntitiesJson (Join-Path $script:FixtureDir 'entities-1.json') `
                -DceEndpoint 'http://example.ingest.monitor.azure.com' `
                -DcrImmutableId 'dcr-123' `
                -StreamName 'Custom-AzureAnalyzerFindings'
        } | Should -Throw '*HTTPS*'
    }

    It 'returns zero batches for empty findings' {
        $path = Join-Path $TestDrive 'empty-entities.json'
        '[]' | Set-Content -Path $path -Encoding UTF8
        $result = Send-FindingsToLogAnalytics `
            -EntitiesJson $path `
            -DceEndpoint 'https://example.eastus-1.ingest.monitor.azure.com' `
            -DcrImmutableId 'dcr-123' `
            -StreamName 'Custom-AzureAnalyzerFindings' `
            -DryRun

        $result.RecordsProcessed | Should -Be 0
        $result.BatchesProcessed | Should -Be 0
    }

    It 'sends a single batch for small payloads' {
        Mock Get-AzAccessToken { [PSCustomObject]@{ Token = 'token-value' } }
        Mock Invoke-RestMethod { return $null }

        $result = Send-FindingsToLogAnalytics `
            -EntitiesJson (Join-Path $script:FixtureDir 'entities-1.json') `
            -DceEndpoint 'https://example.eastus-1.ingest.monitor.azure.com' `
            -DcrImmutableId 'dcr-123' `
            -StreamName 'Custom-AzureAnalyzerFindings'

        $result.RecordsProcessed | Should -Be 1
        $result.BatchesProcessed | Should -Be 1
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }

    It 'splits into multiple batches over 1500 records' {
        Mock Get-AzAccessToken { [PSCustomObject]@{ Token = 'token-value' } }
        Mock Invoke-RestMethod { return $null }

        $result = Send-FindingsToLogAnalytics `
            -EntitiesJson (Join-Path $script:FixtureDir 'entities-2000.json') `
            -DceEndpoint 'https://example.eastus-1.ingest.monitor.azure.com' `
            -DcrImmutableId 'dcr-123' `
            -StreamName 'Custom-AzureAnalyzerFindings'

        $result.RecordsProcessed | Should -Be 2000
        $result.BatchesProcessed | Should -BeGreaterThan 1
        Should -Invoke Invoke-RestMethod -Times $result.BatchesProcessed -Exactly
    }

    It 'uses Invoke-WithRetry around REST calls' {
        Mock Get-AzAccessToken { [PSCustomObject]@{ Token = 'token-value' } }
        Mock Invoke-RestMethod { return $null }
        Mock Invoke-WithRetry { param([scriptblock]$ScriptBlock) & $ScriptBlock }

        Send-FindingsToLogAnalytics `
            -EntitiesJson (Join-Path $script:FixtureDir 'entities-1.json') `
            -DceEndpoint 'https://example.eastus-1.ingest.monitor.azure.com' `
            -DcrImmutableId 'dcr-123' `
            -StreamName 'Custom-AzureAnalyzerFindings' | Out-Null

        Should -Invoke Invoke-WithRetry -Times 1 -Exactly
    }

    It 'handles mocked 429 retry path via Invoke-WithRetry' {
        $script:restCalls = 0
        Mock Get-AzAccessToken { [PSCustomObject]@{ Token = 'token-value' } }
        Mock Invoke-RestMethod {
            $script:restCalls++
            if ($script:restCalls -eq 1) {
                throw [System.Exception]::new('429 Too Many Requests')
            }
            return $null
        }
        Mock Invoke-WithRetry {
            param([scriptblock]$ScriptBlock)
            $attempt = 0
            while ($true) {
                try {
                    $attempt++
                    return & $ScriptBlock
                } catch {
                    if ($attempt -ge 2) { throw }
                }
            }
        }

        {
            Send-FindingsToLogAnalytics `
                -EntitiesJson (Join-Path $script:FixtureDir 'entities-1.json') `
                -DceEndpoint 'https://example.eastus-1.ingest.monitor.azure.com' `
                -DcrImmutableId 'dcr-123' `
                -StreamName 'Custom-AzureAnalyzerFindings'
        } | Should -Not -Throw

        $script:restCalls | Should -Be 2
    }

    It 'writes dry-run output and skips REST call' {
        Mock Invoke-RestMethod { throw 'REST should not be called in dry-run mode.' }

        $result = Send-FindingsToLogAnalytics `
            -EntitiesJson (Join-Path $script:FixtureDir 'entities-100.json') `
            -DceEndpoint 'https://example.eastus-1.ingest.monitor.azure.com' `
            -DcrImmutableId 'dcr-123' `
            -StreamName 'Custom-AzureAnalyzerFindings' `
            -DryRun

        Test-Path $result.DryRunOutputPath | Should -BeTrue
        Should -Invoke Invoke-RestMethod -Times 0
    }

    It 'includes idempotency keys in dry-run payload' {
        $result = Send-FindingsToLogAnalytics `
            -EntitiesJson (Join-Path $script:FixtureDir 'entities-1.json') `
            -DceEndpoint 'https://example.eastus-1.ingest.monitor.azure.com' `
            -DcrImmutableId 'dcr-123' `
            -StreamName 'Custom-AzureAnalyzerFindings' `
            -DryRun

        $rows = Get-Content -Path $result.DryRunOutputPath -Raw | ConvertFrom-Json
        $body = $rows[0].Body | ConvertFrom-Json
        $body[0].RunId | Should -Not -BeNullOrEmpty
        $body[0].EntityId | Should -Not -BeNullOrEmpty
        $body[0].FindingId | Should -Not -BeNullOrEmpty
    }
}

Describe 'Send-EntitiesToLogAnalytics' {
    It 'sends entities using separate stream' {
        Mock Get-AzAccessToken { [PSCustomObject]@{ Token = 'token-value' } }
        Mock Invoke-RestMethod { return $null }

        $result = Send-EntitiesToLogAnalytics `
            -EntitiesJson (Join-Path $script:FixtureDir 'entities-2000.json') `
            -DceEndpoint 'https://example.eastus-1.ingest.monitor.azure.com' `
            -DcrImmutableId 'dcr-123' `
            -StreamName 'Custom-AzureAnalyzerEntities'

        $result.RecordsProcessed | Should -Be 2000
        $result.BatchesProcessed | Should -BeGreaterThan 1
        Should -Invoke Invoke-RestMethod -Times $result.BatchesProcessed -Exactly
    }
}
