#Requires -Version 7.4

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\ReportArchitecture.ps1')
}

Describe 'Select-ReportArchitecture' {
    It 'selects PureJson below thresholds' {
        $r = Select-ReportArchitecture -FindingCount 100 -EntityCount 50 -EdgeCount 100
        $r.Tier | Should -Be 'PureJson'
    }

    It 'selects EmbeddedSqlite at 10k findings' {
        $r = Select-ReportArchitecture -FindingCount 10000 -EntityCount 100 -EdgeCount 10 -HeadroomFactor 1.0
        $r.Tier | Should -Be 'EmbeddedSqlite'
    }

    It 'selects SidecarSqlite at 100k findings' {
        $r = Select-ReportArchitecture -FindingCount 100000 -EntityCount 100 -EdgeCount 10 -HeadroomFactor 1.0
        $r.Tier | Should -Be 'SidecarSqlite'
    }

    It 'selects PodeViewer above 500k findings or 50k edges' {
        (Select-ReportArchitecture -FindingCount 500001 -EntityCount 0 -EdgeCount 0 -HeadroomFactor 1.0).Tier | Should -Be 'PodeViewer'
        (Select-ReportArchitecture -FindingCount 10 -EntityCount 0 -EdgeCount 50001 -HeadroomFactor 1.0).Tier | Should -Be 'PodeViewer'
    }

    It 'applies headroom and takes max tier across inputs' {
        $r = Select-ReportArchitecture -FindingCount 9000 -EntityCount 9000 -EdgeCount 10000 -HeadroomFactor 1.25
        $r.Tier | Should -Be 'EmbeddedSqlite'
        $r.Headroom.Findings | Should -Be 11250
        $r.Headroom.Edges | Should -Be 12500
    }

    It 'honors force override and flags override state' {
        $old = $env:AZURE_ANALYZER_FORCE_ARCH
        try {
            $env:AZURE_ANALYZER_FORCE_ARCH = 'PureJson'
            $r = Select-ReportArchitecture -FindingCount 200000 -EntityCount 0 -EdgeCount 0 -HeadroomFactor 1.0
            $r.ForcedOverride | Should -BeTrue
            $r.Tier | Should -Be 'PureJson'
        } finally {
            $env:AZURE_ANALYZER_FORCE_ARCH = $old
        }
    }
}
