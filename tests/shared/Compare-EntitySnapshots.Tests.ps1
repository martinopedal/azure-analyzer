Set-StrictMode -Version Latest

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    . (Join-Path $repoRoot 'modules' 'shared' 'Sanitize.ps1')
    . (Join-Path $repoRoot 'modules' 'shared' 'Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules' 'shared' 'Compare-EntitySnapshots.ps1')

    $fixtureRoot = Join-Path $repoRoot 'tests' 'fixtures' 'entities-snapshots'
    $baselinePath = Join-Path $fixtureRoot 'baseline.json'
    $addedPath = Join-Path $fixtureRoot 'added.json'
    $removedPath = Join-Path $fixtureRoot 'removed.json'
    $modifiedPath = Join-Path $fixtureRoot 'modified.json'
}

Describe 'Compare-EntitySnapshots' {
    It 'returns zero drift for identical snapshots' {
        $result = Compare-EntitySnapshots -Previous $baselinePath -Current $baselinePath
        $result.Added.Count | Should -Be 0
        $result.Removed.Count | Should -Be 0
        $result.Modified.Count | Should -Be 0
        $result.Unchanged.Count | Should -Be 3
    }

    It 'detects pure add drift (new tenant)' {
        $result = Compare-EntitySnapshots -Previous $baselinePath -Current $addedPath
        $result.Added.Count | Should -Be 1
        $result.Removed.Count | Should -Be 0
        $result.Modified.Count | Should -Be 0
        $result.Added[0].EntityType | Should -Be 'Tenant'
    }

    It 'detects pure remove drift (deleted service principal)' {
        $result = Compare-EntitySnapshots -Previous $baselinePath -Current $removedPath
        $result.Added.Count | Should -Be 0
        $result.Removed.Count | Should -Be 1
        $result.Modified.Count | Should -Be 0
        $result.Removed[0].EntityId | Should -Be 'appId:22222222-2222-2222-2222-222222222222'
    }

    It 'detects modified drift and marks RBAC-relevant changes as Medium' {
        $result = Compare-EntitySnapshots -Previous $baselinePath -Current $modifiedPath
        $result.Added.Count | Should -Be 0
        $result.Removed.Count | Should -Be 0
        $result.Modified.Count | Should -Be 1
        $result.Modified[0].Severity | Should -Be 'Medium'
        (@($result.Modified[0].ChangedPaths) -join ' ') | Should -Match 'Detail'
    }

    It 'ignores volatile provenance fields during deep compare' {
        $tmp = Join-Path $TestDrive 'volatile-only'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $lhs = Join-Path $tmp 'lhs.json'
        $rhs = Join-Path $tmp 'rhs.json'

        $base = Get-Content -Path $baselinePath -Raw | ConvertFrom-Json -Depth 100
        $variant = Get-Content -Path $baselinePath -Raw | ConvertFrom-Json -Depth 100
        $variant.Entities[2].Observations[0].Id = 'different-id'
        $variant.Entities[2].Observations[0].Provenance.RunId = 'run-x'
        $variant.Entities[2].Observations[0].Provenance.Timestamp = '2027-01-01T00:00:00Z'
        $variant.Entities[2].Observations[0].Provenance.RawRecordRef = 'different-row'

        $base | ConvertTo-Json -Depth 100 | Set-Content -Path $lhs -Encoding UTF8
        $variant | ConvertTo-Json -Depth 100 | Set-Content -Path $rhs -Encoding UTF8

        $result = Compare-EntitySnapshots -Previous $lhs -Current $rhs
        $result.Modified.Count | Should -Be 0
        $result.Unchanged.Count | Should -Be 3
    }

    It 'supports array-root entities payloads' {
        $tmp = Join-Path $TestDrive 'array-root'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $lhs = Join-Path $tmp 'lhs.json'
        $rhs = Join-Path $tmp 'rhs.json'

        $base = Get-Content -Path $baselinePath -Raw | ConvertFrom-Json -Depth 100
        $base.Entities | ConvertTo-Json -Depth 100 | Set-Content -Path $lhs -Encoding UTF8
        $base.Entities | ConvertTo-Json -Depth 100 | Set-Content -Path $rhs -Encoding UTF8

        $result = Compare-EntitySnapshots -Previous $lhs -Current $rhs
        $result.Unchanged.Count | Should -Be 3
    }

    It 'canonicalizes tenant IDs when keying entities' {
        $tmp = Join-Path $TestDrive 'canonical-tenant'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $lhs = Join-Path $tmp 'lhs.json'
        $rhs = Join-Path $tmp 'rhs.json'

        $leftPayload = @{
            SchemaVersion = '3.0'
            Entities = @(
                @{
                    EntityId = '11111111-1111-1111-1111-111111111111'
                    EntityType = 'Tenant'
                    Platform = 'Entra'
                    Observations = @()
                }
            )
        }
        $rightPayload = @{
            SchemaVersion = '3.0'
            Entities = @(
                @{
                    EntityId = 'tenant:11111111-1111-1111-1111-111111111111'
                    EntityType = 'Tenant'
                    Platform = 'Entra'
                    Observations = @()
                }
            )
        }
        $leftPayload | ConvertTo-Json -Depth 20 | Set-Content -Path $lhs -Encoding UTF8
        $rightPayload | ConvertTo-Json -Depth 20 | Set-Content -Path $rhs -Encoding UTF8

        $result = Compare-EntitySnapshots -Previous $lhs -Current $rhs
        $result.Unchanged.Count | Should -Be 1
        $result.Added.Count | Should -Be 0
        $result.Removed.Count | Should -Be 0
    }

    It 'detects mixed drift (add, remove, and modify)' {
        $tmp = Join-Path $TestDrive 'mixed'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $currentPath = Join-Path $tmp 'mixed-current.json'

        $mixed = Get-Content -Path $modifiedPath -Raw | ConvertFrom-Json -Depth 100
        # Remove baseline SPN
        $mixed.Entities = @($mixed.Entities | Where-Object { $_.EntityId -ne 'appId:22222222-2222-2222-2222-222222222222' })
        # Add a new tenant
        $mixed.Entities += [pscustomobject]@{
            EntityId = 'tenant:55555555-5555-5555-5555-555555555555'
            EntityType = 'Tenant'
            Platform = 'Entra'
            DisplayName = 'Extra tenant'
            Observations = @()
        }
        $mixed | ConvertTo-Json -Depth 100 | Set-Content -Path $currentPath -Encoding UTF8

        $result = Compare-EntitySnapshots -Previous $baselinePath -Current $currentPath
        $result.Added.Count | Should -Be 1
        $result.Removed.Count | Should -Be 1
        $result.Modified.Count | Should -Be 1
    }

    It 'finds latest previous run directory with entities.json' {
        $root = Join-Path $TestDrive 'runs'
        $null = New-Item -ItemType Directory -Path $root -Force
        $runOld = Join-Path $root 'run-old'
        $runNew = Join-Path $root 'run-new'
        $runCurrent = Join-Path $root 'run-current'
        foreach ($d in @($runOld, $runNew, $runCurrent)) {
            $null = New-Item -ItemType Directory -Path $d -Force
            '{}' | Set-Content -Path (Join-Path $d 'entities.json') -Encoding UTF8
        }
        (Get-Item $runOld).LastWriteTimeUtc = [datetime]'2026-01-01T00:00:00Z'
        (Get-Item $runNew).LastWriteTimeUtc = [datetime]'2026-01-02T00:00:00Z'
        (Get-Item $runCurrent).LastWriteTimeUtc = [datetime]'2026-01-03T00:00:00Z'

        $latest = Get-LatestPreviousRun -OutputRoot $root -CurrentRunDir $runCurrent
        $latest | Should -Be $runNew
    }
}
