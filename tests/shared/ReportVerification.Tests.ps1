#Requires -Version 7.4

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\ReportArchitecture.ps1')
    . (Join-Path $repoRoot 'modules\shared\ReportManifest.ps1')
    . (Join-Path $repoRoot 'modules\shared\ReportVerification.ps1')
}

Describe 'Report verification stubs' {
    It 'returns Success/Errors/Warnings shape for each tier' {
        foreach ($fn in @('Test-PureJsonOutput', 'Test-EmbeddedSqliteOutput', 'Test-SidecarSqliteOutput', 'Test-PodeViewerOutput')) {
            $r = & $fn -OutputPath $TestDrive
            $r.PSObject.Properties.Name | Should -Contain 'Success'
            $r.PSObject.Properties.Name | Should -Contain 'Errors'
            $r.PSObject.Properties.Name | Should -Contain 'Warnings'
        }
    }

    It 'times out verification with helper' {
        $r = Invoke-VerificationWithTimeout -TimeoutSeconds 1 -ScriptBlock { Start-Sleep -Seconds 3; [pscustomobject]@{ Success = $true; Errors = @(); Warnings = @() } }
        $r.Success | Should -BeFalse
        ($r.Errors -join ';') | Should -Match 'timed out'
    }
}

Describe 'Invoke-AutoUpgradeIfFailed' {
    It 'upgrades once, rewrites manifest, and succeeds' {
        $selection = [pscustomobject]@{
            Tier = 'PureJson'
            Measurements = [pscustomobject]@{ Findings = 15000; Entities = 1200; Edges = 1000 }
            Reasoning = @('findings=>EmbeddedSqlite')
            ForcedOverride = $false
        }
        $failed = [pscustomobject]@{ Success = $false; Errors = @('initial fail'); Warnings = @() }
        $manifest = Join-Path $TestDrive 'report-manifest.json'
        $verify = {
            param($tier)
            [pscustomobject]@{ Success = $true; Errors = @(); Warnings = @("tier:$tier") }
        }

        $result = Invoke-AutoUpgradeIfFailed `
            -ArchitectureSelection $selection `
            -VerificationResult $failed `
            -VerifyScript $verify `
            -ManifestPath $manifest `
            -CurrentFeatures @([pscustomobject]@{ name = 'A'; available = $true }) `
            -UpgradedFeatures @([pscustomobject]@{ name = 'A'; available = $true }) `
            -HeadroomFactor 1.0

        $result.AutoUpgraded | Should -BeTrue
        $result.Tier | Should -Be 'EmbeddedSqlite'
        (Get-Content $manifest -Raw | ConvertFrom-Json).SelectedTier | Should -Be 'EmbeddedSqlite'
    }

    It 'throws when upgraded verification fails' {
        $selection = [pscustomobject]@{
            Tier = 'EmbeddedSqlite'
            Measurements = [pscustomobject]@{ Findings = 12000; Entities = 10; Edges = 10 }
        }
        $failed = [pscustomobject]@{ Success = $false; Errors = @('initial fail'); Warnings = @() }
        { Invoke-AutoUpgradeIfFailed -ArchitectureSelection $selection -VerificationResult $failed -VerifyScript { param($tier) [pscustomobject]@{ Success = $false; Errors = @('still bad'); Warnings = @() } } } | Should -Throw
    }
}
