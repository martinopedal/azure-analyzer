#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Policy\AzAdvertizerLookup.ps1')
}

Describe 'AzAdvertizer policy lookup' -Tag 'policy' {
    It 'loads and validates the curated finding-to-policy mapping table' {
        $map = Import-FindingToPolicyMap
        $map.schemaVersion | Should -Be '1.0.0'
        @($map.entries).Count | Should -BeGreaterThan 0
    }

    It 'resolves AzAdvertizer catalog entries from vendored snapshot by policy ID' {
        $hit = Invoke-AzAdvertizerLookup -PolicyId '/providers/Microsoft.Authorization/policyDefinitions/b2982f36-99f2-4db5-8eff-283140c09693'
        $hit | Should -Not -BeNullOrEmpty
        $hit.url | Should -Match '^https://www\.azadvertizer\.net/'
    }

    It 'returns AzAdvertizer-only suggestions in fallback mode' {
        $finding = [pscustomobject]@{ FindingType = 'storage.publicNetworkAccess.enabled' }
        $suggestions = Get-PolicySuggestionsForFinding -Finding $finding -AlzActivation Fallback -MaxSuggestions 5
        @($suggestions).Count | Should -Be 1
        @($suggestions | Select-Object -ExpandProperty Source -Unique) | Should -Be @('AzAdvertizer')
    }

    It 'returns ALZ and AzAdvertizer suggestions in active mode' {
        $finding = [pscustomobject]@{ FindingType = 'storage.publicNetworkAccess.enabled' }
        $suggestions = Get-PolicySuggestionsForFinding -Finding $finding -AlzActivation Full -MaxSuggestions 5
        @($suggestions).Count | Should -Be 2
        @($suggestions | Select-Object -ExpandProperty Pill -Unique) | Should -Contain 'ALZ'
        @($suggestions | Select-Object -ExpandProperty Pill -Unique) | Should -Contain 'AzAdvertizer'
    }

    It 'surfaces catalog vintage metadata for banner/manifests' {
        $vintage = Get-CatalogVintage
        $vintage.azAdvertizer.catalogVintage | Should -Be '2026-04-23'
        $vintage.azAdvertizer.catalogSha | Should -Match '^[a-f0-9]{40}$'
        $vintage.alz.catalogVintage | Should -Be '2026-04-23'
        $vintage.alz.catalogSha | Should -Match '^[a-f0-9]{40}$'
    }
}
