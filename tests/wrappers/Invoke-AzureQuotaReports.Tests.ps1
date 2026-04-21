#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:Wrapper = Join-Path $script:RepoRoot 'modules' 'Invoke-AzureQuotaReports.ps1'
    $script:FixtureRoot = Join-Path $script:RepoRoot 'tests' 'fixtures' 'azure-quota' 'cli'
    $script:SubA = '11111111-1111-1111-1111-111111111111'
    $script:SubB = '22222222-2222-2222-2222-222222222222'
    $global:QuotaCliFixtures = @{}

    function Read-CliFixture {
        param([Parameter(Mandatory)][string] $Name)
        Get-Content (Join-Path $script:FixtureRoot $Name) -Raw
    }

    $script:AccountList = Read-CliFixture -Name 'account-list.json'
    $script:LocationsA = Read-CliFixture -Name "list-locations-$($script:SubA).json"
    $script:LocationsB = Read-CliFixture -Name "list-locations-$($script:SubB).json"
    $script:LocationsEmpty = Read-CliFixture -Name 'list-locations-empty.json'
    $script:VmAEastUs = Read-CliFixture -Name "vm-list-usage-$($script:SubA)-eastus.json"
    $script:VmAWestEurope = Read-CliFixture -Name "vm-list-usage-$($script:SubA)-westeurope.json"
    $script:VmBEastUs2 = Read-CliFixture -Name "vm-list-usage-$($script:SubB)-eastus2.json"
    $script:VmSecret = Read-CliFixture -Name 'vm-list-usage-secret.json'
    $script:NetAEastUs = Read-CliFixture -Name "network-list-usages-$($script:SubA)-eastus.json"
    $script:NetAWestEurope = Read-CliFixture -Name "network-list-usages-$($script:SubA)-westeurope.json"
    $script:NetBEastUs2 = Read-CliFixture -Name "network-list-usages-$($script:SubB)-eastus2.json"

    $global:QuotaCliFixtures = @{
        SubA         = $script:SubA
        SubB         = $script:SubB
        AccountList  = $script:AccountList
        LocationsA   = $script:LocationsA
        LocationsB   = $script:LocationsB
        LocationsEmpty = $script:LocationsEmpty
        VmAEastUs    = $script:VmAEastUs
        VmAWestEurope = $script:VmAWestEurope
        VmBEastUs2   = $script:VmBEastUs2
        VmSecret     = $script:VmSecret
        NetAEastUs   = $script:NetAEastUs
        NetAWestEurope = $script:NetAWestEurope
        NetBEastUs2  = $script:NetBEastUs2
    }

    function global:Get-AzFixtureResponse {
        param([Parameter(Mandatory)][string[]] $Arguments)
        $joined = ($Arguments -join ' ')

        if ($joined -match '^account list-locations\b') {
            if ($joined -match '--subscription\s+([0-9a-fA-F-]{36})') {
                $sub = $Matches[1].ToLowerInvariant()
                if ($sub -eq $global:QuotaCliFixtures.SubA.ToLowerInvariant()) { return [PSCustomObject]@{ ExitCode = 0; Output = $global:QuotaCliFixtures.LocationsA } }
                if ($sub -eq $global:QuotaCliFixtures.SubB.ToLowerInvariant()) { return [PSCustomObject]@{ ExitCode = 0; Output = $global:QuotaCliFixtures.LocationsB } }
            }
            return [PSCustomObject]@{ ExitCode = 0; Output = '[]' }
        }

        if ($joined -match '^account list\b') {
            return [PSCustomObject]@{ ExitCode = 0; Output = $global:QuotaCliFixtures.AccountList }
        }

        if ($joined -match '^account set\b') {
            return [PSCustomObject]@{ ExitCode = 0; Output = '' }
        }

        if ($joined -match '^vm list-usage\b') {
            $subMatch = [regex]::Match($joined, '--subscription\s+([0-9a-fA-F-]{36})')
            $locMatch = [regex]::Match($joined, '--location\s+([a-z0-9-]+)')
            if ($subMatch.Success -and $locMatch.Success) {
                $sub = $subMatch.Groups[1].Value.ToLowerInvariant()
                $loc = $locMatch.Groups[1].Value.ToLowerInvariant()
                if ($sub -eq $global:QuotaCliFixtures.SubA.ToLowerInvariant() -and $loc -eq 'eastus') { return [PSCustomObject]@{ ExitCode = 0; Output = $global:QuotaCliFixtures.VmAEastUs } }
                if ($sub -eq $global:QuotaCliFixtures.SubA.ToLowerInvariant() -and $loc -eq 'westeurope') { return [PSCustomObject]@{ ExitCode = 0; Output = $global:QuotaCliFixtures.VmAWestEurope } }
                if ($sub -eq $global:QuotaCliFixtures.SubB.ToLowerInvariant() -and $loc -eq 'eastus2') { return [PSCustomObject]@{ ExitCode = 0; Output = $global:QuotaCliFixtures.VmBEastUs2 } }
            }
            return [PSCustomObject]@{ ExitCode = 0; Output = '[]' }
        }

        if ($joined -match '^network list-usages\b') {
            $subMatch = [regex]::Match($joined, '--subscription\s+([0-9a-fA-F-]{36})')
            $locMatch = [regex]::Match($joined, '--location\s+([a-z0-9-]+)')
            if ($subMatch.Success -and $locMatch.Success) {
                $sub = $subMatch.Groups[1].Value.ToLowerInvariant()
                $loc = $locMatch.Groups[1].Value.ToLowerInvariant()
                if ($sub -eq $global:QuotaCliFixtures.SubA.ToLowerInvariant() -and $loc -eq 'eastus') { return [PSCustomObject]@{ ExitCode = 0; Output = $global:QuotaCliFixtures.NetAEastUs } }
                if ($sub -eq $global:QuotaCliFixtures.SubA.ToLowerInvariant() -and $loc -eq 'westeurope') { return [PSCustomObject]@{ ExitCode = 0; Output = $global:QuotaCliFixtures.NetAWestEurope } }
                if ($sub -eq $global:QuotaCliFixtures.SubB.ToLowerInvariant() -and $loc -eq 'eastus2') { return [PSCustomObject]@{ ExitCode = 0; Output = $global:QuotaCliFixtures.NetBEastUs2 } }
            }
            return [PSCustomObject]@{ ExitCode = 0; Output = '[]' }
        }

        return [PSCustomObject]@{ ExitCode = 1; Output = "Unexpected az invocation: $joined" }
    }
}

Describe 'Invoke-AzureQuotaReports' {
    AfterAll {
        if (Test-Path 'Function:global:Get-AzFixtureResponse') {
            Remove-Item 'Function:global:Get-AzFixtureResponse' -ErrorAction SilentlyContinue
        }
        Remove-Variable -Name QuotaCliFixtures -Scope Global -ErrorAction SilentlyContinue
    }

    BeforeEach {
        function global:az {
            [CmdletBinding()]
            param()
        }
        function global:Invoke-WithRetry {
            param(
                [scriptblock] $ScriptBlock,
                [Nullable[int]] $MaxAttempts,
                [Nullable[int]] $InitialDelaySeconds,
                [Nullable[int]] $MaxDelaySeconds
            )
            & $ScriptBlock
        }
        function global:Invoke-WithTimeout {
            param([string] $Command, [string[]] $Arguments, [int] $TimeoutSec = 300)
            Get-AzFixtureResponse -Arguments $Arguments
        }
    }

    AfterEach {
        foreach ($fn in @('az', 'Invoke-WithRetry', 'Invoke-WithTimeout')) {
            if (Test-Path "Function:global:$fn") {
                Remove-Item "Function:global:$fn" -ErrorAction SilentlyContinue
            }
        }
        Remove-Variable -Name QuotaAzCalls -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name QuotaVmCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It 'fans out across multiple enabled subscriptions' {
        $result = & $script:Wrapper

        $result.Status | Should -Be 'Success'
        (@($result.Findings.SubscriptionId | Select-Object -Unique)).Count | Should -Be 2
        $result.Findings.SubscriptionId | Should -Contain $script:SubA
        $result.Findings.SubscriptionId | Should -Contain $script:SubB
    }

    It 'sets Source to azure-quota on emitted findings' {
        $result = & $script:Wrapper -Subscriptions @($script:SubA) -Locations @('eastus')
        $result.Status | Should -Be 'Success'
        (@($result.Findings | Where-Object { $_.Source -eq 'azure-quota' })).Count | Should -Be @($result.Findings).Count
    }

    It 'fans out across multiple regions per subscription' {
        $result = & $script:Wrapper -Subscriptions @($script:SubA)
        $result.Status | Should -Be 'Success'

        $locations = @($result.Findings.Location | Select-Object -Unique)
        $locations | Should -Contain 'eastus'
        $locations | Should -Contain 'westeurope'
    }

    It 'retries transient vm list-usage failures via Invoke-WithRetry' {
        $global:QuotaVmCalls = 0
        function global:Invoke-WithRetry {
            param(
                [scriptblock] $ScriptBlock,
                [Nullable[int]] $MaxAttempts,
                [Nullable[int]] $InitialDelaySeconds,
                [Nullable[int]] $MaxDelaySeconds
            )
            $attempts = if ($null -ne $MaxAttempts) { [int]$MaxAttempts } else { 4 }
            for ($i = 0; $i -lt $attempts; $i++) {
                try { return & $ScriptBlock } catch { if ($i -eq ($attempts - 1)) { throw } }
            }
        }
        function global:Invoke-WithTimeout {
            param([string] $Command, [string[]] $Arguments, [int] $TimeoutSec)
            $joined = $Arguments -join ' '
            if ($joined -match '^vm list-usage\b' -and $joined -match [regex]::Escape($global:QuotaCliFixtures.SubA) -and $joined -match '--location eastus\b') {
                $global:QuotaVmCalls++
                if ($global:QuotaVmCalls -eq 1) {
                    return [PSCustomObject]@{ ExitCode = 1; Output = '429 Too Many Requests. Bearer sk_live_retryme' }
                }
            }
            Get-AzFixtureResponse -Arguments $Arguments
        }

        $result = & $script:Wrapper -Subscriptions @($script:SubA) -Locations @('eastus')
        $result.Status | Should -Be 'Success'
        $global:QuotaVmCalls | Should -Be 2
    }

    It 'surfaces permanent vm list-usage failures using sanitized New-InstallerError payloads' {
        function global:Invoke-WithTimeout {
            param([string] $Command, [string[]] $Arguments, [int] $TimeoutSec)
            $joined = $Arguments -join ' '
            if ($joined -match '^vm list-usage\b') {
                return [PSCustomObject]@{ ExitCode = 1; Output = 'Unauthorized with Bearer sk_live_permanent' }
            }
            Get-AzFixtureResponse -Arguments $Arguments
        }

        $result = & $script:Wrapper -Subscriptions @($script:SubA) -Locations @('eastus')
        $result.Status | Should -Be 'Failed'
        $result.Message | Should -Match '"Tool":"azure-quota"'
        $result.Message | Should -Match '"Category":"ExecutionFailed"'
        $result.Message | Should -Not -Match 'sk_live_permanent'
    }

    It 'returns success with no records when a subscription has no enabled regions' {
        function global:Invoke-WithTimeout {
            param([string] $Command, [string[]] $Arguments, [int] $TimeoutSec)
            $joined = $Arguments -join ' '
            if ($joined -match '^account list-locations\b') {
                return [PSCustomObject]@{ ExitCode = 0; Output = $global:QuotaCliFixtures.LocationsEmpty }
            }
            Get-AzFixtureResponse -Arguments $Arguments
        }

        $result = & $script:Wrapper -Subscriptions @($script:SubB)
        $result.Status | Should -Be 'Success'
        @($result.Findings).Count | Should -Be 0
    }

    It 'narrows fanout when -Subscriptions is supplied' {
        $result = & $script:Wrapper -Subscriptions @($script:SubA)
        $result.Status | Should -Be 'Success'
        (@($result.Findings.SubscriptionId | Select-Object -Unique)).Count | Should -Be 1
        $result.Findings[0].SubscriptionId | Should -Be $script:SubA
    }

    It 'narrows fanout when -Locations is supplied' {
        $result = & $script:Wrapper -Locations @('eastus')
        $result.Status | Should -Be 'Success'
        @($result.Findings.Location | Select-Object -Unique) | Should -Be @('eastus')
    }

    It 'passes -Threshold through to the v1 envelope for downstream normalizer policy' {
        $result = & $script:Wrapper -Subscriptions @($script:SubA) -Locations @('eastus') -Threshold 70
        $result.Status | Should -Be 'Success'
        @($result.Findings).Count | Should -BeGreaterThan 0
        foreach ($finding in @($result.Findings)) {
            $finding.Threshold | Should -Be 70
            $finding.Detail | Should -Match 'Threshold=70%'
        }
    }

    It 'sanitizes output before writing to disk' {
        function global:Invoke-WithTimeout {
            param([string] $Command, [string[]] $Arguments, [int] $TimeoutSec)
            $joined = $Arguments -join ' '
            if ($joined -match '^vm list-usage\b') {
                return [PSCustomObject]@{ ExitCode = 0; Output = $global:QuotaCliFixtures.VmSecret }
            }
            Get-AzFixtureResponse -Arguments $Arguments
        }
        $outDir = Join-Path $script:RepoRoot 'output-test' 'quota-wrapper-tests'
        if (-not (Test-Path $outDir)) { $null = New-Item -ItemType Directory -Path $outDir -Force }
        $outPath = Join-Path $outDir 'quota-sanitized.json'

        $result = & $script:Wrapper -Subscriptions @($script:SubA) -Locations @('eastus') -OutputPath $outPath
        $result.Status | Should -Be 'Success'
        $written = Get-Content $outPath -Raw
        $written | Should -Not -Match 'ghp_AbCdEfGhIjKlMnOpQrStUvWxYz1234567890'
        $written | Should -Match '\[GITHUB-PAT-REDACTED\]'
    }

    It 'returns strict v1 envelope shape with SchemaVersion 1.0 and raw findings array' {
        $result = & $script:Wrapper -Subscriptions @($script:SubA) -Locations @('eastus')
        $result.SchemaVersion | Should -Be '1.0'
        $result.Source | Should -Be 'azure-quota'
        @($result.Findings).Count | Should -BeGreaterThan 0
        $result.Findings[0].PSObject.Properties.Name | Should -Contain 'UsagePercent'
        $result.Findings[0].PSObject.Properties.Name | Should -Contain 'SubscriptionId'
        $result.Findings[0].PSObject.Properties.Name | Should -Not -Contain 'EntityId'
    }
}
