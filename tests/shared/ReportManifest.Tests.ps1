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

    It 'honors headroom_factor from manifest config when -HeadroomFactor is unbound' {
        $cfg = Get-DefaultReportArchitectureConfig
        $cfg.headroom_factor = 2.0
        # 6000 * 2.0 = 12000 >= 10000 embedded threshold
        $selection = Select-ReportArchitecture -FindingCount 6000 -EntityCount 0 -EdgeCount 0 -ArchitectureConfig $cfg
        $selection.Tier | Should -Be 'EmbeddedSqlite'
        $selection.Headroom.Factor | Should -Be 2.0
    }

    It 'lets explicit -HeadroomFactor override manifest config' {
        $cfg = Get-DefaultReportArchitectureConfig
        $cfg.headroom_factor = 5.0
        $selection = Select-ReportArchitecture -FindingCount 100 -EntityCount 0 -EdgeCount 0 -HeadroomFactor 1.0 -ArchitectureConfig $cfg
        $selection.Headroom.Factor | Should -Be 1.0
        $selection.Tier | Should -Be 'PureJson'
    }

    It 'applies default_tier as a floor across all axes' {
        $cfg = Get-DefaultReportArchitectureConfig
        $cfg.default_tier = 'EmbeddedSqlite'
        $selection = Select-ReportArchitecture -FindingCount 5 -EntityCount 5 -EdgeCount 5 -HeadroomFactor 1.0 -ArchitectureConfig $cfg
        $selection.Tier | Should -Be 'EmbeddedSqlite'
    }

    It 'validates threshold monotonicity and rejects misordered config' {
        $cfg = Get-DefaultReportArchitectureConfig
        $cfg.thresholds.findings.sidecar = 5  # below embedded=10000 -> not monotonic
        { Select-ReportArchitecture -FindingCount 1 -ArchitectureConfig $cfg } | Should -Throw -ExpectedMessage '*monotonic*'
    }

    It 'rejects null threshold values' {
        $cfg = Get-DefaultReportArchitectureConfig
        $cfg.thresholds.findings.embedded = $null
        { Select-ReportArchitecture -FindingCount 1 -ArchitectureConfig $cfg } | Should -Throw -ExpectedMessage '*null*'
    }

    It 'rejects unknown default_tier value' {
        $cfg = Get-DefaultReportArchitectureConfig
        $cfg.default_tier = 'NotARealTier'
        { Select-ReportArchitecture -FindingCount 1 -ArchitectureConfig $cfg } | Should -Throw -ExpectedMessage '*default_tier*'
    }
}

Describe 'Get-ReportVerificationStubs placeholder semantics' {
    It 'reports placeholder tiers as Success=$false with Status=placeholder' {
        $verify = Get-ReportVerificationStubs
        $verify.PureJson.Success | Should -BeTrue
        $verify.PureJson.Status | Should -Be 'ready'
        foreach ($tier in 'EmbeddedSqlite','SidecarSqlite','PodeViewer') {
            $verify.$tier.Success | Should -BeFalse
            $verify.$tier.Status | Should -Be 'placeholder'
        }
    }

    It 'placeholder verifier functions report Success=$false' {
        (Test-CytoscapePlaceholder).Success | Should -BeFalse
        (Test-DagrePlaceholder).Success | Should -BeFalse
        (Test-PodePlaceholder).Success | Should -BeFalse
        (Test-SqliteWasmPlaceholder).Success | Should -BeFalse
    }
}

Describe 'New-ReportManifest atomic write' {
    It 'does not leave a temp file behind on success' {
        $path = Join-Path $TestDrive 'atomic.json'
        $null = New-ReportManifest -Path $path -SelectedTier 'PureJson'
        Test-Path $path | Should -BeTrue
        @(Get-ChildItem -Path $TestDrive -Filter 'atomic.json.tmp-*').Count | Should -Be 0
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

    It 'persists policy ALZ audit shape when provided' {
        $path = Join-Path $TestDrive 'report-manifest-policy.json'
        $policy = [pscustomobject]@{
            alz = [pscustomobject]@{
                mode = 'Auto'
                score = 0.82
                components = [pscustomobject]@{
                    exactName = 0.40
                    structural = 0.24
                    renames = 0.18
                    levenshtein = 0.00
                }
            }
            azAdvertizer = [pscustomobject]@{
                catalogVintage = '2026-04-23'
                catalogSha = 'ea952a6e70811ee2d6568b92fee5db0e4e9aa02d'
            }
        }
        $manifest = New-ReportManifest -Path $path -SelectedTier 'PureJson' -Policy $policy
        $manifest.Policy.alz.mode | Should -Be 'Auto'

        $roundTrip = Get-Content -Path $path -Raw | ConvertFrom-Json
        $roundTrip.Policy.alz.mode | Should -Be 'Auto'
        $roundTrip.Policy.azAdvertizer.catalogVintage | Should -Be '2026-04-23'
    }
}
