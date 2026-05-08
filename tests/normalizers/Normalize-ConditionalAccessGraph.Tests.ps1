#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    . (Join-Path $repoRoot 'modules' 'shared' 'Schema.ps1')
    . (Join-Path $repoRoot 'modules' 'shared' 'Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules' 'shared' 'Sanitize.ps1')
    . (Join-Path $repoRoot 'modules' 'normalizers' 'Normalize-ConditionalAccessGraph.ps1')

    $script:Fixture = Get-Content (Join-Path $repoRoot 'tests' 'fixtures' 'conditional-access-graph-output.json') -Raw | ConvertFrom-Json
}

Describe 'Normalize-ConditionalAccessGraph' {
    BeforeAll {
        $script:Result = Normalize-ConditionalAccessGraph -ToolResult $script:Fixture
        $script:Rows   = @($script:Result.Findings)
        $script:Edges  = @($script:Result.Edges)
    }

    It 'returns one FindingRow per fixture finding' {
        $script:Rows.Count | Should -Be 4
    }

    It 'sets Source = conditional-access-graph on every row' {
        @($script:Rows | Where-Object { $_.Source -ne 'conditional-access-graph' }).Count | Should -Be 0
    }

    It 'sets EntityType = ConditionalAccessPolicy and Platform = Entra' {
        @($script:Rows | Where-Object { $_.EntityType -ne 'ConditionalAccessPolicy' }).Count | Should -Be 0
        @($script:Rows | Where-Object { $_.Platform   -ne 'Entra' }).Count                   | Should -Be 0
    }

    It 'canonicalises the policy entity id to cap:{lowercased-guid}' {
        $row = $script:Rows | Select-Object -First 1
        $row.EntityId | Should -Match '^cap:[0-9a-f-]{36}$'
    }

    It 'preserves the Critical-severity finding for GA excluded from MFA' {
        $crit = @($script:Rows | Where-Object { $_.Severity -eq 'Critical' })
        $crit.Count | Should -Be 1
        $crit[0].RuleId | Should -Be 'ca-ga-excluded-from-mfa'
    }

    It 'sets Pillar = Identity on every row' {
        @($script:Rows | Where-Object { $_.Pillar -ne 'Identity' }).Count | Should -Be 0
    }

    It 'all findings are non-compliant' {
        @($script:Rows | Where-Object { $_.Compliant }).Count | Should -Be 0
    }

    It 'SchemaVersion = 2.2 on every row' {
        @($script:Rows | Where-Object { $_.SchemaVersion -ne '2.2' }).Count | Should -Be 0
    }

    It 'emits AppliesTo and Excludes edges from the projections' {
        $applies  = @($script:Edges | Where-Object { $_.Relation -eq 'AppliesTo' })
        $excludes = @($script:Edges | Where-Object { $_.Relation -eq 'Excludes'  })
        $applies.Count  | Should -BeGreaterThan 0
        $excludes.Count | Should -BeGreaterThan 0
    }

    It 'edge Source ids are cap:{guid}-shaped policy ids' {
        @($script:Edges | Where-Object { $_.Source -notmatch '^cap:[0-9a-f-]{36}$' }).Count | Should -Be 0
    }

    It 'edge Platform = Entra and DiscoveredBy = conditional-access-graph' {
        @($script:Edges | Where-Object { $_.Platform -ne 'Entra' }).Count                            | Should -Be 0
        @($script:Edges | Where-Object { $_.DiscoveredBy -ne 'conditional-access-graph' }).Count    | Should -Be 0
    }

    It 'filters the All / None sentinel out of edge targets' {
        @($script:Edges | Where-Object { $_.Target -in @('All','None','GuestsOrExternalUsers','all','none') }).Count | Should -Be 0
    }

    Context 'with non-Success input' {
        It 'returns an envelope with empty Findings and Edges arrays' {
            $bad = [PSCustomObject]@{ Source='conditional-access-graph'; Status='Failed'; Findings=@(); Policies=@() }
            $r = Normalize-ConditionalAccessGraph -ToolResult $bad
            @($r.Findings).Count | Should -Be 0
            @($r.Edges).Count    | Should -Be 0
        }
    }
}
