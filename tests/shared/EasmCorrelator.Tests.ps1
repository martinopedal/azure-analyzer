#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'EasmCorrelator.ps1')

    $script:Entities = @(
        [PSCustomObject]@{
            EntityId   = '/subscriptions/sub1/resourcegroups/rg/providers/microsoft.network/publicipaddresses/pip1'
            EntityType = 'AzureResource'
            Attributes = [PSCustomObject]@{ PublicIp = '20.30.40.50'; Hostname = 'pip1.westeurope.cloudapp.azure.com' }
        },
        [PSCustomObject]@{
            EntityId   = '/subscriptions/sub1/resourcegroups/rg/providers/microsoft.network/frontdoors/fd1'
            EntityType = 'AzureResource'
            Attributes = [PSCustomObject]@{ Fqdn = 'app.example.com' }
        },
        [PSCustomObject]@{
            EntityId   = '/subscriptions/sub1/resourcegroups/rg/providers/microsoft.web/sites/api'
            EntityType = 'AzureResource'
            Attributes = [PSCustomObject]@{ FrontendFqdn = 'API.contoso.com' }
        },
        # Non-AzureResource entities should be ignored by the index builder.
        [PSCustomObject]@{
            EntityId   = 'github.com/org/repo'
            EntityType = 'Repository'
            Attributes = [PSCustomObject]@{ Hostname = 'should-be-ignored.example.com' }
        }
    )

    $script:Index = Get-EasmEntityIndex -Entities $script:Entities
}

Describe 'Get-EasmEntityIndex' {
    It 'indexes AzureResource public IPs' {
        $script:Index.Ips.ContainsKey('20.30.40.50') | Should -BeTrue
    }

    It 'indexes AzureResource hostnames case-insensitively' {
        $script:Index.Hosts.ContainsKey('app.example.com')  | Should -BeTrue
        $script:Index.Hosts.ContainsKey('API.contoso.com')  | Should -BeTrue
        $script:Index.Hosts.ContainsKey('api.contoso.com')  | Should -BeTrue
        $script:Index.Hosts.ContainsKey('pip1.westeurope.cloudapp.azure.com') | Should -BeTrue
    }

    It 'ignores non-AzureResource entities' {
        $script:Index.Hosts.ContainsKey('should-be-ignored.example.com') | Should -BeFalse
    }
}

Describe 'Resolve-EasmEntity' {
    It 'resolves a known host to AzureResource' {
        $r = Resolve-EasmEntity -Index $script:Index -HostName 'app.example.com'
        $r.EntityType | Should -Be 'AzureResource'
        $r.Platform   | Should -Be 'Azure'
        $r.Confidence | Should -Be 'Confirmed'
        $r.MatchedOn  | Should -Be 'host'
    }

    It 'resolves a known IP to AzureResource' {
        $r = Resolve-EasmEntity -Index $script:Index -Ip '20.30.40.50'
        $r.EntityType | Should -Be 'AzureResource'
        $r.MatchedOn  | Should -Be 'ip'
    }

    It 'prefers host match over IP match when both are supplied' {
        $r = Resolve-EasmEntity -Index $script:Index -HostName 'app.example.com' -Ip '20.30.40.50'
        $r.MatchedOn | Should -Be 'host'
    }

    It 'falls back to ExternalAsset for unknown host' {
        $r = Resolve-EasmEntity -Index $script:Index -HostName 'unknown.attacker.example'
        $r.EntityType | Should -Be 'ExternalAsset'
        $r.Platform   | Should -Be 'External'
        $r.Confidence | Should -Be 'Unconfirmed'
        $r.EntityId   | Should -Be 'host:unknown.attacker.example'
        $r.MatchedOn  | Should -Be 'none'
    }

    It 'falls back to ExternalAsset for unknown IP' {
        $r = Resolve-EasmEntity -Index $script:Index -Ip '198.51.100.1'
        $r.EntityType | Should -Be 'ExternalAsset'
        $r.EntityId   | Should -Be 'ip:198.51.100.1'
    }

    It 'returns external:unknown when neither input is supplied' {
        $r = Resolve-EasmEntity -Index $script:Index
        $r.EntityId | Should -Be 'external:unknown'
    }

    It 'is case-insensitive on host lookup' {
        $r = Resolve-EasmEntity -Index $script:Index -HostName 'APP.example.com'
        $r.MatchedOn | Should -Be 'host'
    }
}
