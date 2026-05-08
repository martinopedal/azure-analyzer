#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    . (Join-Path $repoRoot 'modules' 'shared' 'Schema.ps1')
    . (Join-Path $repoRoot 'modules' 'shared' 'Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules' 'shared' 'EasmCorrelator.ps1')
    . (Join-Path $repoRoot 'modules' 'normalizers' 'Normalize-DnsTwist.ps1')

    $script:Fixture = Get-Content (Join-Path $repoRoot 'tests' 'fixtures' 'dnstwist-output.json') -Raw | ConvertFrom-Json
}

Describe 'Normalize-DnsTwist' {
    BeforeAll {
        $script:Rows = @(Normalize-DnsTwist -ToolResult $script:Fixture)
    }

    It 'returns one row per fixture finding' {
        $script:Rows.Count | Should -Be 4
    }

    It 'sets Source = dnstwist on every row' {
        @($script:Rows | Where-Object { $_.Source -ne 'dnstwist' }).Count | Should -Be 0
    }

    It 'sets EntityType = ExternalAsset and Platform = External when no index supplied' {
        @($script:Rows | Where-Object { $_.EntityType -ne 'ExternalAsset' }).Count | Should -Be 0
        @($script:Rows | Where-Object { $_.Platform   -ne 'External' }).Count       | Should -Be 0
    }

    It 'maps homoglyph variant to High severity' {
        $homo = $script:Rows | Where-Object { $_.RuleId -eq 'dnstwist-homoglyph' } | Select-Object -First 1
        $homo.Severity | Should -Be 'High'
    }

    It 'maps tld-swap variant to Low severity' {
        $tld = $script:Rows | Where-Object { $_.RuleId -eq 'dnstwist-tld-swap' } | Select-Object -First 1
        $tld.Severity | Should -Be 'Low'
    }

    It 'sets Pillar = Exposure on every row' {
        @($script:Rows | Where-Object { $_.Pillar -ne 'Exposure' }).Count | Should -Be 0
    }

    It 'all findings are non-compliant' {
        @($script:Rows | Where-Object { $_.Compliant }).Count | Should -Be 0
    }

    It 'SchemaVersion = 2.2 on every row' {
        @($script:Rows | Where-Object { $_.SchemaVersion -ne '2.2' }).Count | Should -Be 0
    }

    It 'BaselineTags include fuzzer + seed metadata' {
        $row = $script:Rows | Select-Object -First 1
        ($row.BaselineTags -join ',') | Should -Match 'dnstwist:fuzzer:'
        ($row.BaselineTags -join ',') | Should -Match 'dnstwist:seed:contoso.com'
    }

    It 'sets EntityId to host:lowercased-domain for ExternalAsset' {
        $row = $script:Rows | Where-Object { $_.RuleId -eq 'dnstwist-typo' } | Select-Object -First 1
        $row.EntityId | Should -Be 'host:contso.com'
    }

    It 'sets Confidence = Unconfirmed for ExternalAsset rows' {
        @($script:Rows | Where-Object { $_.Confidence -ne 'Unconfirmed' }).Count | Should -Be 0
    }

    Context 'with EntityIndex correlating an Azure-owned host' {
        BeforeAll {
            $entities = @(
                [PSCustomObject]@{
                    EntityId   = '/subscriptions/11111111-1111-1111-1111-111111111111/resourcegroups/rg/providers/microsoft.cdn/profiles/c0ntoso'
                    EntityType = 'AzureResource'
                    Attributes = [PSCustomObject]@{ Hostname = 'c0ntoso.com' }
                }
            )
            $idx = Get-EasmEntityIndex -Entities $entities
            $script:CorrelatedRows = @(Normalize-DnsTwist -ToolResult $script:Fixture -EntityIndex $idx)
        }

        It 'anchors the matching row to AzureResource' {
            $r = $script:CorrelatedRows | Where-Object { $_.RuleId -eq 'dnstwist-homoglyph' } | Select-Object -First 1
            $r.EntityType | Should -Be 'AzureResource'
            $r.Platform   | Should -Be 'Azure'
            $r.Confidence | Should -Be 'Confirmed'
            $r.EntityId   | Should -Match 'microsoft.cdn/profiles/c0ntoso'
        }

        It 'leaves unmatched rows as ExternalAsset' {
            $r = $script:CorrelatedRows | Where-Object { $_.RuleId -eq 'dnstwist-typo' } | Select-Object -First 1
            $r.EntityType | Should -Be 'ExternalAsset'
        }
    }

    Context 'with non-Success input' {
        It 'returns empty array when Status is not Success' {
            $bad = [PSCustomObject]@{ Source='dnstwist'; Status='Failed'; Findings=@() }
            @(Normalize-DnsTwist -ToolResult $bad).Count | Should -Be 0
        }
    }
}
