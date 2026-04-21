#Requires -Version 7.4

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\ReportManifest.ps1')
}

Describe 'New-ReportManifest' {
    It 'writes schema 1.0 manifest with degradations subset' {
        $out = Join-Path $TestDrive 'report-manifest.json'
        $features = @(
            [pscustomobject]@{ name = 'FindingsTable'; renderingMode = 'interactive'; tier1Mode = 'interactive'; tradeoff = '' },
            [pscustomobject]@{ name = 'GraphCanvas'; renderingMode = 'summary'; tier1Mode = 'interactive'; tradeoff = 'reduced fidelity' }
        )

        $manifest = New-ReportManifest `
            -Path $out `
            -SelectedTier 'EmbeddedSqlite' `
            -Measurements ([pscustomobject]@{ Findings = 12000; Entities = 4000; Edges = 3000 }) `
            -PickerReasoning @('findings=>EmbeddedSqlite') `
            -ForcedOverride $false `
            -VerificationResults ([pscustomobject]@{ EmbeddedSqlite = [pscustomobject]@{ Success = $true; Errors = @(); Warnings = @() } }) `
            -AutoUpgrades @() `
            -Timings ([pscustomobject]@{ renderMs = 1200 }) `
            -Features $features

        $manifest.SchemaVersion | Should -Be '1.0'
        $manifest.SelectedTier | Should -Be 'EmbeddedSqlite'
        @($manifest.Features).Count | Should -Be 2
        @($manifest.Degradations).Count | Should -Be 1
        $manifest.Degradations[0].name | Should -Be 'GraphCanvas'

        $loaded = Get-Content -Path $out -Raw | ConvertFrom-Json
        $loaded.SchemaVersion | Should -Be '1.0'
        @($loaded.Degradations).Count | Should -Be 1
    }
}
