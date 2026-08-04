Describe 'AprlCatalog' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' '..' 'modules' 'shared' 'AprlCatalog.ps1')

        $script:catalogRecords = @(
            [pscustomobject]@{
                aprlGuid             = 'AAAA1111-2222-3333-4444-555566667777'
                description          = 'Use zone-redundant storage for critical data'
                recommendationImpact = 'High'
                longDescription      = 'Zone-redundant storage replicates data synchronously across three availability zones.'
                learnMoreLink        = @([pscustomobject]@{ name = 'ZRS docs'; url = 'https://learn.microsoft.com/azure/storage/zrs' })
            },
            [pscustomobject]@{
                aprlGuid             = 'BBBB1111-2222-3333-4444-555566667777'
                description          = 'Enable soft delete on Key Vault'
                recommendationImpact = 'Medium'
                longDescription      = 'Soft delete protects against accidental or malicious deletion.'
                learnMoreLink        = @([pscustomobject]@{ url = 'https://learn.microsoft.com/azure/key-vault/soft-delete' })
            }
        )

        function New-WaraFinding {
            param([string] $Id, [string] $RecommendationId, [string] $Title, [string] $Severity, [string] $Detail, [string] $LearnMoreUrl)
            [pscustomobject]@{
                Id               = $Id
                RecommendationId = $RecommendationId
                Title            = $Title
                Severity         = $Severity
                Detail           = $Detail
                LearnMoreUrl     = $LearnMoreUrl
                DeepLinkUrl      = $LearnMoreUrl
            }
        }
    }

    Context 'ConvertTo-WaraAprlCatalog' {
        It 'builds a lowercased GUID-keyed hashtable' {
            $catalog = ConvertTo-WaraAprlCatalog -Records $script:catalogRecords
            $catalog.Count | Should -Be 2
            $catalog.ContainsKey('aaaa1111-2222-3333-4444-555566667777') | Should -BeTrue
            $catalog['bbbb1111-2222-3333-4444-555566667777'].description | Should -Be 'Enable soft delete on Key Vault'
        }

        It 'skips records without a GUID' {
            $records = @([pscustomobject]@{ description = 'no guid here' })
            (ConvertTo-WaraAprlCatalog -Records $records).Count | Should -Be 0
        }
    }

    Context 'Merge-WaraAprlMetadata' {
        BeforeEach {
            $script:catalog = ConvertTo-WaraAprlCatalog -Records $script:catalogRecords
        }

        It 'backfills Title/Severity/Detail/LearnMore for an Unknown finding via RecommendationId' {
            $f = New-WaraFinding -Id 'AAAA1111-2222-3333-4444-555566667777::/sub/x' -RecommendationId 'AAAA1111-2222-3333-4444-555566667777' -Title 'Unknown' -Severity 'Medium' -Detail '' -LearnMoreUrl ''
            Merge-WaraAprlMetadata -Findings @($f) -Catalog $script:catalog | Out-Null
            $f.Title        | Should -Be 'Use zone-redundant storage for critical data'
            $f.Severity     | Should -Be 'High'
            $f.Detail       | Should -Be 'Zone-redundant storage replicates data synchronously across three availability zones.'
            $f.LearnMoreUrl | Should -Be 'https://learn.microsoft.com/azure/storage/zrs'
            $f.DeepLinkUrl  | Should -Be 'https://learn.microsoft.com/azure/storage/zrs'
        }

        It 'resolves the GUID from the Id when RecommendationId is empty' {
            $f = New-WaraFinding -Id 'BBBB1111-2222-3333-4444-555566667777::/sub/y' -RecommendationId '' -Title '' -Severity '' -Detail '' -LearnMoreUrl ''
            Merge-WaraAprlMetadata -Findings @($f) -Catalog $script:catalog | Out-Null
            $f.Title        | Should -Be 'Enable soft delete on Key Vault'
            $f.LearnMoreUrl | Should -Be 'https://learn.microsoft.com/azure/key-vault/soft-delete'
        }

        It 'does not clobber a finding that already has a real Title' {
            $f = New-WaraFinding -Id 'AAAA1111-2222-3333-4444-555566667777::/sub/z' -RecommendationId 'AAAA1111-2222-3333-4444-555566667777' -Title 'Custom reviewed title' -Severity 'Low' -Detail 'kept' -LearnMoreUrl 'https://example.test/kept'
            Merge-WaraAprlMetadata -Findings @($f) -Catalog $script:catalog | Out-Null
            $f.Title        | Should -Be 'Custom reviewed title'
            $f.Severity     | Should -Be 'Low'
            $f.Detail       | Should -Be 'kept'
            $f.LearnMoreUrl | Should -Be 'https://example.test/kept'
        }

        It 'leaves findings unchanged when the GUID is not in the catalog' {
            $f = New-WaraFinding -Id 'CCCC0000-0000-0000-0000-000000000000::/sub/q' -RecommendationId 'CCCC0000-0000-0000-0000-000000000000' -Title 'Unknown' -Severity 'Medium' -Detail '' -LearnMoreUrl ''
            Merge-WaraAprlMetadata -Findings @($f) -Catalog $script:catalog | Out-Null
            $f.Title | Should -Be 'Unknown'
        }

        It 'returns findings unchanged for an empty catalog' {
            $f = New-WaraFinding -Id 'AAAA1111-2222-3333-4444-555566667777::/sub/x' -RecommendationId 'AAAA1111-2222-3333-4444-555566667777' -Title 'Unknown' -Severity 'Medium' -Detail '' -LearnMoreUrl ''
            Merge-WaraAprlMetadata -Findings @($f) -Catalog @{} | Out-Null
            $f.Title | Should -Be 'Unknown'
        }
    }

    Context 'Get-AprlLearnMoreUrl' {
        It 'reads a url from an array of link objects' {
            Get-AprlLearnMoreUrl -Record $script:catalogRecords[0] | Should -Be 'https://learn.microsoft.com/azure/storage/zrs'
        }

        It 'returns empty string when no link is present' {
            Get-AprlLearnMoreUrl -Record ([pscustomobject]@{ description = 'x' }) | Should -Be ''
        }

        It 'rejects non-HTTPS schemes' -ForEach @(
            @{ Bad = 'javascript:alert(document.domain)' }
            @{ Bad = 'http://learn.microsoft.com/insecure' }
            @{ Bad = 'data:text/html;base64,PHNjcmlwdD4=' }
            @{ Bad = 'file:///etc/passwd' }
            @{ Bad = 'not a url at all' }
        ) {
            $record = [pscustomobject]@{ learnMoreLink = @([pscustomobject]@{ url = $Bad }) }
            Get-AprlLearnMoreUrl -Record $record | Should -Be ''
        }
    }

    Context 'hostile catalog cannot poison the report' {
        It 'never writes a javascript: URL onto a finding' {
            # The HTML report renders LearnMoreUrl/DeepLinkUrl as <a href='...'>.
            # HTML-encoding does not neutralise a hostile scheme, so it must be
            # rejected here at ingest.
            $poison = [pscustomobject]@{
                aprlGuid             = 'DDDD1111-2222-3333-4444-555566667777'
                description          = 'Poisoned recommendation'
                recommendationImpact = 'High'
                learnMoreLink        = @([pscustomobject]@{ url = 'javascript:alert(document.domain)' })
            }
            $catalog = ConvertTo-WaraAprlCatalog -Records @($poison)
            $f = New-WaraFinding -Id 'x' -RecommendationId 'DDDD1111-2222-3333-4444-555566667777' -Title 'Unknown' -Severity 'Medium' -Detail '' -LearnMoreUrl ''
            Merge-WaraAprlMetadata -Findings @($f) -Catalog $catalog | Out-Null

            $f.Title        | Should -Be 'Poisoned recommendation'   # text still enriched
            $f.LearnMoreUrl | Should -Be ''                          # but no hostile link
            $f.DeepLinkUrl  | Should -Be ''
        }
    }

    Context 'ConvertTo-AprlSeverity' {
        It 'maps <In> to <Out>' -ForEach @(
            @{ In = 'Critical'; Out = 'Critical' }
            @{ In = 'High';     Out = 'High' }
            @{ In = 'Medium';   Out = 'Medium' }
            @{ In = 'Low';      Out = 'Low' }
        ) {
            ConvertTo-AprlSeverity $In | Should -Be $Out
        }

        It 'clamps an unrecognised value to a valid severity' {
            # Schema.ps1 allows exactly Critical|High|Medium|Low|Info.
            ConvertTo-AprlSeverity 'Verified' | Should -BeIn @('Critical', 'High', 'Medium', 'Low', 'Info')
        }
    }

    Context 'Get-WaraAprlCatalog cache freshness' {
        BeforeEach {
            $script:cachePath = Join-Path $TestDrive ("aprl-{0}.json" -f ([guid]::NewGuid().ToString('N')))
            '[{"aprlGuid":"EEEE1111-2222-3333-4444-555566667777","description":"CACHED ENTRY"}]' |
                Set-Content -Path $script:cachePath -Encoding UTF8
        }

        It 'uses a fresh cache without any network call' {
            $catalog = Get-WaraAprlCatalog -Path $script:cachePath -Url 'https://invalid.invalid/never.json'
            $catalog.ContainsKey('eeee1111-2222-3333-4444-555566667777') | Should -BeTrue
        }

        It 'does not blindly trust a cache older than MaxAgeHours' {
            (Get-Item $script:cachePath).LastWriteTime = (Get-Date).AddDays(-400)
            # Unreachable URL: the stale entry may still be returned as a
            # fallback, but only after a refresh was attempted.
            $catalog = Get-WaraAprlCatalog -Path $script:cachePath -Url 'https://invalid.invalid/never.json' -MaxAgeHours 168 -WarningAction SilentlyContinue
            $verbose = Get-WaraAprlCatalog -Path $script:cachePath -Url 'https://invalid.invalid/never.json' -MaxAgeHours 168 -Verbose 4>&1 |
                Where-Object { $_ -is [System.Management.Automation.VerboseRecord] }
            ($verbose -join ' ') | Should -Match 'old|refresh'
        }

        It 'MaxAgeHours of 0 disables expiry' {
            (Get-Item $script:cachePath).LastWriteTime = (Get-Date).AddDays(-400)
            $catalog = Get-WaraAprlCatalog -Path $script:cachePath -Url 'https://invalid.invalid/never.json' -MaxAgeHours 0
            $catalog.ContainsKey('eeee1111-2222-3333-4444-555566667777') | Should -BeTrue
        }
    }

    Context 'Get-AprlDefaultCachePath' {
        It 'is user-scoped, not the shared temp directory' {
            $path = Get-AprlDefaultCachePath
            $path | Should -Match 'azure-analyzer'
            $path | Should -Match 'wara-aprl-catalog\.json$'
        }
    }
}
