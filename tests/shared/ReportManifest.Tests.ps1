#Requires -Version 7.4

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\ReportManifest.ps1')
}

Describe 'Select-ReportArchitecture picker defaults' {
    It 'defaults to PureJson for small datasets' {
        $selection = Select-ReportArchitecture -FindingCount 120 -EntityCount 80 -EdgeCount 40
        $selection.Tier | Should -Be 'PureJson'
    }

    It 'promotes to EmbeddedSqlite at threshold' {
        $selection = Select-ReportArchitecture -FindingCount 10000 -EntityCount 50 -EdgeCount 10 -HeadroomFactor 1.0
        $selection.Tier | Should -Be 'EmbeddedSqlite'
    }

    It 'honors forced tier override from environment variable' {
        $original = $env:AZURE_ANALYZER_FORCE_ARCH
        try {
            $env:AZURE_ANALYZER_FORCE_ARCH = 'PureJson'
            $selection = Select-ReportArchitecture -FindingCount 200000 -EntityCount 500 -EdgeCount 100 -HeadroomFactor 1.0
            $selection.ForcedOverride | Should -BeTrue
            $selection.Tier | Should -Be 'PureJson'
        } finally {
            $env:AZURE_ANALYZER_FORCE_ARCH = $original
        }
    }
}

Describe 'New-ReportManifest serialization' {
    It 'writes report-manifest.json with schema and degradations' {
        $path = Join-Path $TestDrive 'report-manifest.json'
        $features = @(
            [pscustomobject]@{ name = 'FindingsTable'; renderingMode = 'interactive'; tier1Mode = 'interactive' },
            [pscustomobject]@{ name = 'GraphCanvas'; renderingMode = 'summary'; tier1Mode = 'interactive' }
        )
        $verification = Get-ReportVerificationStubs
        $manifest = New-ReportManifest `
            -Path $path `
            -SelectedTier 'EmbeddedSqlite' `
            -Measurements ([pscustomobject]@{ Findings = 12000; Entities = 4000; Edges = 3000 }) `
            -PickerReasoning @('findings=>EmbeddedSqlite') `
            -ForcedOverride $false `
            -VerificationResults $verification `
            -Features $features

        $manifest.SchemaVersion | Should -Be '1.0'
        $manifest.SelectedTier | Should -Be 'EmbeddedSqlite'
        @($manifest.Degradations).Count | Should -Be 1
        Test-Path $path | Should -BeTrue

        $roundTrip = Get-Content -Path $path -Raw | ConvertFrom-Json
        $roundTrip.SchemaVersion | Should -Be '1.0'
        $roundTrip.VerificationResults.PodeViewer.Dependencies | Should -Contain 'Pode'
        $roundTrip.VerificationResults.EmbeddedSqlite.Dependencies | Should -Contain 'sqlite-wasm'
    }
}
