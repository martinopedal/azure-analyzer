#Requires -Version 7.4
<#
Tests for the azure-function/Shared/Invoke-FunctionScan.ps1 entrypoint.
Mocks the orchestrator script and the Log Analytics sink so we exercise:
  - GUID validation on subscriptionId / tenantId
  - includeTools allow-list rejection
  - environment-variable defaulting
  - opt-in sink invocation (skipped cleanly when DCE_ENDPOINT is empty)
  - error sanitization through Remove-Credentials
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Sanitize.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'sinks' 'Send-FindingsToLogAnalytics.ps1')
    . (Join-Path $script:RepoRoot 'azure-function' 'Shared' 'Invoke-FunctionScan.ps1')

    # Replace the path-resolved orchestrator so we never hit Az SDK in tests.
    $script:FakeAnalyzer = Join-Path $TestDrive 'Invoke-AzureAnalyzer.ps1'
    @'
param ([string]$SubscriptionId, [string]$TenantId, [string]$OutputPath, [string[]]$IncludeTools, [switch]$SkipPrereqCheck)
$entitiesPath = Join-Path $OutputPath 'entities.json'
'[]' | Set-Content -Path $entitiesPath -Encoding UTF8
return
'@ | Set-Content -Path $script:FakeAnalyzer -Encoding UTF8

    $script:OriginalRepoRoot = $script:RepoRoot
}

Describe 'Invoke-FunctionScan: input validation' {
    BeforeEach {
        # Rebind module-scoped repo root to a TestDrive shim that contains
        # only the fake orchestrator. Keeps the real sink module loaded.
        $stub = Join-Path $TestDrive 'shim'
        New-Item -ItemType Directory -Force -Path $stub | Out-Null
        Copy-Item -Path $script:FakeAnalyzer -Destination (Join-Path $stub 'Invoke-AzureAnalyzer.ps1') -Force
        Set-Variable -Scope Script -Name RepoRoot -Value $stub
    }

    It 'throws when subscriptionId is missing' {
        { Invoke-FunctionScan -RequestBody @{} -EnvOverride @{} } | Should -Throw '*subscriptionId is required*'
    }

    It 'throws when subscriptionId is not a GUID' {
        { Invoke-FunctionScan -RequestBody @{ subscriptionId = 'not-a-guid' } -EnvOverride @{} } |
            Should -Throw '*not a valid GUID*'
    }

    It 'throws when tenantId is provided but malformed' {
        $env = @{ AZURE_ANALYZER_SUBSCRIPTION_ID = '11111111-2222-3333-4444-555555555555' }
        { Invoke-FunctionScan -RequestBody @{ tenantId = 'bad' } -EnvOverride $env } |
            Should -Throw '*tenantId is not a valid GUID*'
    }

    It 'rejects tools that are not on the allow-list' {
        $env = @{ AZURE_ANALYZER_SUBSCRIPTION_ID = '11111111-2222-3333-4444-555555555555' }
        { Invoke-FunctionScan -RequestBody @{ includeTools = @('azqr', 'not-a-real-tool') } -EnvOverride $env } |
            Should -Throw '*not allowed*'
    }

    It 'accepts allow-listed tools as a CSV string' {
        $env = @{
            AZURE_ANALYZER_SUBSCRIPTION_ID = '11111111-2222-3333-4444-555555555555'
            AZURE_ANALYZER_INCLUDE_TOOLS   = 'azqr, psrule'
            AZURE_ANALYZER_OUTPUT_PATH     = (Join-Path $TestDrive 'out')
        }
        $result = Invoke-FunctionScan -RequestBody @{} -EnvOverride $env -TriggerName 'unit'
        $result.RunId | Should -Match '^\d{8}T\d{6}Z-unit$'
        Test-Path $result.EntitiesPath | Should -BeTrue
    }
}

Describe 'Invoke-FunctionScan: sink wiring' {
    BeforeEach {
        $stub = Join-Path $TestDrive 'shim2'
        New-Item -ItemType Directory -Force -Path $stub | Out-Null
        Copy-Item -Path $script:FakeAnalyzer -Destination (Join-Path $stub 'Invoke-AzureAnalyzer.ps1') -Force
        Set-Variable -Scope Script -Name RepoRoot -Value $stub
    }

    It 'skips the sink cleanly when DCE_ENDPOINT is empty' {
        Mock Send-FindingsToLogAnalytics { throw 'sink should not be called' }
        Mock Send-EntitiesToLogAnalytics { throw 'sink should not be called' }
        $env = @{
            AZURE_ANALYZER_SUBSCRIPTION_ID = '11111111-2222-3333-4444-555555555555'
            AZURE_ANALYZER_OUTPUT_PATH     = (Join-Path $TestDrive 'out2')
        }
        $result = Invoke-FunctionScan -RequestBody @{} -EnvOverride $env -TriggerName 'unit'
        $result.Sink | Should -BeNullOrEmpty
        Should -Invoke Send-FindingsToLogAnalytics -Times 0
    }

    It 'invokes the sink when DCE_ENDPOINT and DCR_IMMUTABLE_ID are set' {
        Mock Send-FindingsToLogAnalytics { return [pscustomobject]@{ RecordsProcessed = 0 } }
        Mock Send-EntitiesToLogAnalytics { return [pscustomobject]@{ RecordsProcessed = 0 } }
        $env = @{
            AZURE_ANALYZER_SUBSCRIPTION_ID = '11111111-2222-3333-4444-555555555555'
            AZURE_ANALYZER_OUTPUT_PATH     = (Join-Path $TestDrive 'out3')
            DCE_ENDPOINT                   = 'https://example.eastus-1.ingest.monitor.azure.com'
            DCR_IMMUTABLE_ID               = 'dcr-test-1234567890abcdef'
            SINK_DRY_RUN                   = 'true'
        }
        $result = Invoke-FunctionScan -RequestBody @{} -EnvOverride $env -TriggerName 'unit'
        $result.Sink | Should -Not -BeNullOrEmpty
        Should -Invoke Send-FindingsToLogAnalytics -Times 1 -Exactly
        Should -Invoke Send-EntitiesToLogAnalytics -Times 1 -Exactly
    }

    It 'does not fail the run when the sink throws (matches orchestrator -SinkLogAnalytics behavior)' {
        Mock Send-FindingsToLogAnalytics { throw 'transient 503 from monitor.azure.com' }
        Mock Send-EntitiesToLogAnalytics { return [pscustomobject]@{ RecordsProcessed = 0 } }
        $env = @{
            AZURE_ANALYZER_SUBSCRIPTION_ID = '11111111-2222-3333-4444-555555555555'
            AZURE_ANALYZER_OUTPUT_PATH     = (Join-Path $TestDrive 'out4')
            DCE_ENDPOINT                   = 'https://example.eastus-1.ingest.monitor.azure.com'
            DCR_IMMUTABLE_ID               = 'dcr-test-1234567890abcdef'
        }
        $result = Invoke-FunctionScan -RequestBody @{} -EnvOverride $env -TriggerName 'unit'
        $result.Sink | Should -Not -BeNullOrEmpty
        $result.Sink.Error | Should -Match '503'
    }

    It 'sanitizes credential-bearing orchestrator errors through Remove-Credentials' {
        $boom = Join-Path $TestDrive 'boom-analyzer.ps1'
        @'
param ([string]$SubscriptionId, [string]$TenantId, [string]$OutputPath, [string[]]$IncludeTools, [switch]$SkipPrereqCheck)
throw "auth failed: Bearer eyJabcDEFghi1234567890longtoken"
'@ | Set-Content -Path $boom -Encoding UTF8

        $stub = Join-Path $TestDrive 'shim-boom'
        New-Item -ItemType Directory -Force -Path $stub | Out-Null
        Copy-Item -Path $boom -Destination (Join-Path $stub 'Invoke-AzureAnalyzer.ps1') -Force
        Set-Variable -Scope Script -Name RepoRoot -Value $stub

        $env = @{
            AZURE_ANALYZER_SUBSCRIPTION_ID = '11111111-2222-3333-4444-555555555555'
            AZURE_ANALYZER_OUTPUT_PATH     = (Join-Path $TestDrive 'out5')
        }
        $err = $null
        try { Invoke-FunctionScan -RequestBody @{} -EnvOverride $env -TriggerName 'unit' | Out-Null }
        catch { $err = "$_" }

        $err | Should -Not -BeNullOrEmpty
        $err | Should -Match 'REDACTED'
        $err | Should -Not -Match 'eyJabcDEFghi1234567890longtoken'
    }
}
