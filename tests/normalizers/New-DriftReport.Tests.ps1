Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    . (Join-Path $repoRoot 'modules' 'shared' 'Sanitize.ps1')
    . (Join-Path $repoRoot 'modules' 'shared' 'Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules' 'shared' 'Compare-EntitySnapshots.ps1')

    $fixtureRoot = Join-Path $repoRoot 'tests' 'fixtures' 'entities-snapshots'
    $baselinePath = Join-Path $fixtureRoot 'baseline.json'
    $modifiedPath = Join-Path $fixtureRoot 'modified.json'
}

Describe 'New-DriftReport' {
    It 'writes drift-report.json and drift-report.md from snapshot comparison' {
        $out = Join-Path $TestDrive 'drift-report'
        $null = New-Item -ItemType Directory -Path $out -Force

        & (Join-Path $repoRoot 'modules' 'reports' 'New-DriftReport.ps1') `
            -PreviousSnapshot $baselinePath `
            -CurrentSnapshot $modifiedPath `
            -OutputPath $out

        $jsonPath = Join-Path $out 'drift-report.json'
        $mdPath = Join-Path $out 'drift-report.md'
        (Test-Path $jsonPath) | Should -BeTrue
        (Test-Path $mdPath) | Should -BeTrue
    }

    It 'includes grouped change sections and RBAC Medium severity in markdown' {
        $out = Join-Path $TestDrive 'drift-report-groups'
        $null = New-Item -ItemType Directory -Path $out -Force

        & (Join-Path $repoRoot 'modules' 'reports' 'New-DriftReport.ps1') `
            -PreviousSnapshot $baselinePath `
            -CurrentSnapshot $modifiedPath `
            -OutputPath $out

        $md = Get-Content -Path (Join-Path $out 'drift-report.md') -Raw
        $md | Should -Match '## Modified entities'
        $md | Should -Match '### AzureResource'
        $md | Should -Match '\| Medium \|'
    }

    It 'sanitizes sensitive tokens before writing report files' {
        $out = Join-Path $TestDrive 'drift-report-sanitize'
        $null = New-Item -ItemType Directory -Path $out -Force

        $sensitive = 'Bearer eyJhbGciOiJIUzI1NiJ9.fake_payload.fake_sig'
        $comparison = [ordered]@{
            Added = @(
                [pscustomobject]@{
                    ChangeKind = 'Added'
                    EntityId = 'tenant:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                    EntityType = 'Tenant'
                    Platform = 'Entra'
                    Severity = 'Info'
                    ChangedPaths = @()
                    Previous = $null
                    Current = [pscustomobject]@{
                        EntityId = 'tenant:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                        EntityType = 'Tenant'
                        Platform = 'Entra'
                        DisplayName = $sensitive
                        Observations = @()
                    }
                }
            )
            Removed = @()
            Modified = @()
            Unchanged = @()
        }

        & (Join-Path $repoRoot 'modules' 'reports' 'New-DriftReport.ps1') `
            -Comparison $comparison `
            -PreviousSnapshot $baselinePath `
            -CurrentSnapshot $modifiedPath `
            -OutputPath $out

        $jsonRaw = Get-Content -Path (Join-Path $out 'drift-report.json') -Raw
        $mdRaw = Get-Content -Path (Join-Path $out 'drift-report.md') -Raw
        $jsonRaw | Should -Not -Match [regex]::Escape($sensitive)
        $mdRaw | Should -Not -Match [regex]::Escape($sensitive)
    }
}
