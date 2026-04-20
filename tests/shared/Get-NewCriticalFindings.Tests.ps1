#Requires -Version 7.4
<#
Tests for modules/shared/Get-NewCriticalFindings.ps1.

Validates:
  - Get-NewCriticalFindings returns empty when no criticals exist in drift.
  - Get-NewCriticalFindings returns 'New' entries for added entities with Critical observations.
  - Get-NewCriticalFindings ignores added entities that have no Critical observations.
  - Get-NewCriticalFindings returns 'Escalated' entries for modified entities where the
    Critical observation count increased.
  - Get-NewCriticalFindings does NOT flag standing criticals (count unchanged).
  - New-NoBaselineDriftResult wraps all entities as Added (first-run / no baseline mode).
  - First-run mode combined with Get-NewCriticalFindings returns only entities with criticals.
  - Second run with identical findings returns 0 new findings (standing-only suppression).
  - Second run with 1 net-new critical returns exactly 1 new finding.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    . (Join-Path $repoRoot 'modules' 'shared' 'Sanitize.ps1')
    . (Join-Path $repoRoot 'modules' 'shared' 'Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules' 'shared' 'Compare-EntitySnapshots.ps1')
    . (Join-Path $repoRoot 'modules' 'shared' 'Get-NewCriticalFindings.ps1')

    # Helper: build a minimal entity object
    function New-TestEntity {
        param(
            [string] $EntityId,
            [string] $EntityType = 'AzureResource',
            [object[]] $Observations = @()
        )
        [pscustomobject]@{
            EntityId     = $EntityId
            EntityType   = $EntityType
            Platform     = 'Azure'
            Observations = $Observations
        }
    }

    function New-Obs {
        param ([string] $Severity, [string] $Title = '')
        [pscustomobject]@{ Severity = $Severity; Title = $Title }
    }
}

Describe 'Get-NewCriticalFindings' {

    It 'returns empty array when drift result has no entries' {
        $drift = [ordered]@{ Added = @(); Removed = @(); Modified = @(); Unchanged = @() }
        $result = Get-NewCriticalFindings -DriftResult $drift
        @($result).Count | Should -Be 0
    }

    It 'returns New finding for added entity with one Critical observation' {
        $entity = New-TestEntity -EntityId 'sub-1' -Observations @(New-Obs -Severity 'Critical' -Title 'Open RDP')
        $drift = [ordered]@{
            Added     = @([pscustomobject]@{ EntityId = 'sub-1'; EntityType = 'Subscription'; Current = $entity })
            Removed   = @()
            Modified  = @()
            Unchanged = @()
        }
        $result = Get-NewCriticalFindings -DriftResult $drift
        @($result).Count | Should -Be 1
        $result[0].ChangeKind | Should -Be 'New'
        $result[0].EntityId | Should -Be 'sub-1'
        $result[0].CriticalObservationCount | Should -Be 1
        $result[0].Titles | Should -Contain 'Open RDP'
    }

    It 'returns New finding with correct count for multiple Critical observations on one entity' {
        $entity = New-TestEntity -EntityId 'sub-2' -Observations @(
            New-Obs -Severity 'Critical' -Title 'Finding A'
            New-Obs -Severity 'Critical' -Title 'Finding B'
            New-Obs -Severity 'High'     -Title 'High one'
        )
        $drift = [ordered]@{
            Added     = @([pscustomobject]@{ EntityId = 'sub-2'; EntityType = 'Subscription'; Current = $entity })
            Removed   = @(); Modified = @(); Unchanged = @()
        }
        $result = Get-NewCriticalFindings -DriftResult $drift
        @($result).Count | Should -Be 1
        $result[0].CriticalObservationCount | Should -Be 2
    }

    It 'ignores added entity with no Critical observations' {
        $entity = New-TestEntity -EntityId 'app-1' -Observations @(New-Obs -Severity 'High' -Title 'High only')
        $drift = [ordered]@{
            Added     = @([pscustomobject]@{ EntityId = 'app-1'; EntityType = 'AzureResource'; Current = $entity })
            Removed   = @(); Modified = @(); Unchanged = @()
        }
        $result = Get-NewCriticalFindings -DriftResult $drift
        @($result).Count | Should -Be 0
    }

    It 'detects Escalated finding when Critical count increased in modified entity' {
        $prev = New-TestEntity -EntityId 'rg-1' -Observations @(New-Obs -Severity 'High' -Title 'Was High')
        $curr = New-TestEntity -EntityId 'rg-1' -Observations @(
            New-Obs -Severity 'High'     -Title 'Was High'
            New-Obs -Severity 'Critical' -Title 'New Critical'
        )
        $drift = [ordered]@{
            Added = @(); Removed = @()
            Modified = @([pscustomobject]@{
                EntityId = 'rg-1'; EntityType = 'AzureResource'
                Previous = $prev; Current = $curr; ChangedPaths = @()
            })
            Unchanged = @()
        }
        $result = Get-NewCriticalFindings -DriftResult $drift
        @($result).Count | Should -Be 1
        $result[0].ChangeKind | Should -Be 'Escalated'
        $result[0].EntityId | Should -Be 'rg-1'
        $result[0].CriticalObservationCount | Should -Be 1
    }

    It 'does NOT flag a standing critical (count unchanged in modified entity)' {
        $prevObs = New-Obs -Severity 'Critical' -Title 'Standing'
        $currObs = New-Obs -Severity 'Critical' -Title 'Standing'
        $prev = New-TestEntity -EntityId 'rg-2' -Observations @($prevObs)
        $curr = New-TestEntity -EntityId 'rg-2' -Observations @($currObs)
        $drift = [ordered]@{
            Added = @(); Removed = @()
            Modified = @([pscustomobject]@{
                EntityId = 'rg-2'; EntityType = 'AzureResource'
                Previous = $prev; Current = $curr; ChangedPaths = @()
            })
            Unchanged = @()
        }
        $result = Get-NewCriticalFindings -DriftResult $drift
        @($result).Count | Should -Be 0
    }

    It 'handles Unchanged entities without returning any result' {
        $entity = New-TestEntity -EntityId 'tenant-1' -Observations @(New-Obs -Severity 'Critical')
        $drift = [ordered]@{
            Added = @(); Removed = @(); Modified = @()
            Unchanged = @([pscustomobject]@{
                EntityId = 'tenant-1'; EntityType = 'Tenant'
                Previous = $entity; Current = $entity; ChangedPaths = @()
            })
        }
        $result = Get-NewCriticalFindings -DriftResult $drift
        @($result).Count | Should -Be 0
    }

    It 'returns case-insensitive match on critical severity (CRITICAL / Critical / critical)' {
        foreach ($sev in @('CRITICAL', 'Critical', 'critical')) {
            $entity = New-TestEntity -EntityId "e-$sev" -Observations @(New-Obs -Severity $sev)
            $drift = [ordered]@{
                Added     = @([pscustomobject]@{ EntityId = "e-$sev"; EntityType = 'AzureResource'; Current = $entity })
                Removed   = @(); Modified = @(); Unchanged = @()
            }
            $result = Get-NewCriticalFindings -DriftResult $drift
            @($result).Count | Should -Be 1 -Because "Severity '$sev' should be treated as Critical"
        }
    }
}

Describe 'New-NoBaselineDriftResult' {

    It 'returns an all-Added drift result for first-run mode' {
        $tmp  = Join-Path $TestDrive 'first-run'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $path = Join-Path $tmp 'entities.json'
        @{
            SchemaVersion = '3.0'
            Entities      = @(
                @{ EntityId = 'sub-1'; EntityType = 'Subscription'; Platform = 'Azure'; Observations = @() }
                @{ EntityId = 'app-1'; EntityType = 'AzureResource'; Platform = 'Azure'; Observations = @() }
            )
        } | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8

        $drift = New-NoBaselineDriftResult -EntitiesPath $path
        @($drift.Added).Count   | Should -Be 2
        @($drift.Removed).Count | Should -Be 0
        @($drift.Modified).Count | Should -Be 0
        $drift.Added[0].ChangeKind | Should -Be 'Added'
    }

    It 'combined with Get-NewCriticalFindings: first run returns only entities with criticals' {
        $tmp  = Join-Path $TestDrive 'first-run-crit'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $path = Join-Path $tmp 'entities.json'
        @{
            SchemaVersion = '3.0'
            Entities      = @(
                @{
                    EntityId = 'sub-crit'; EntityType = 'Subscription'; Platform = 'Azure'
                    Observations = @(@{ Severity = 'Critical'; Title = 'Critical finding' })
                }
                @{
                    EntityId = 'app-high'; EntityType = 'AzureResource'; Platform = 'Azure'
                    Observations = @(@{ Severity = 'High'; Title = 'High only' })
                }
            )
        } | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8

        $drift  = New-NoBaselineDriftResult -EntitiesPath $path
        $result = Get-NewCriticalFindings -DriftResult $drift
        @($result).Count | Should -Be 1
        $result[0].EntityId | Should -Be 'sub-crit'
        $result[0].ChangeKind | Should -Be 'New'
    }

    It 'first run with no criticals returns 0 new findings' {
        $tmp  = Join-Path $TestDrive 'first-run-nocrit'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $path = Join-Path $tmp 'entities.json'
        @{
            SchemaVersion = '3.0'
            Entities      = @(
                @{ EntityId = 'sub-1'; EntityType = 'Subscription'; Platform = 'Azure'
                   Observations = @(@{ Severity = 'High'; Title = 'High' }) }
            )
        } | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8

        $drift  = New-NoBaselineDriftResult -EntitiesPath $path
        $result = Get-NewCriticalFindings -DriftResult $drift
        @($result).Count | Should -Be 0
    }
}

Describe 'Diff-mode: compare-snapshot integration' {

    It 'second run with identical findings returns 0 new findings (standing suppressed)' {
        $fixtureRoot  = Join-Path $PSScriptRoot '..' 'fixtures' 'entities-snapshots'
        $baselinePath = Join-Path $fixtureRoot 'baseline.json'

        $drift  = Compare-EntitySnapshots -Previous $baselinePath -Current $baselinePath
        $result = Get-NewCriticalFindings -DriftResult $drift
        # baseline has only Info + empty Observations -- no criticals at all
        @($result).Count | Should -Be 0
    }

    It 'second run with 1 net-new critical entity returns exactly 1 new finding' {
        $tmp  = Join-Path $TestDrive 'diff-new-crit'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $prevPath = Join-Path $tmp 'prev.json'
        $currPath = Join-Path $tmp 'curr.json'

        # Previous: one entity, no criticals
        @{
            SchemaVersion = '3.0'
            Entities      = @(
                @{ EntityId = 'sub-1'; EntityType = 'Subscription'; Platform = 'Azure'; Observations = @() }
            )
        } | ConvertTo-Json -Depth 10 | Set-Content -Path $prevPath -Encoding UTF8

        # Current: same entity plus a new critical entity
        @{
            SchemaVersion = '3.0'
            Entities      = @(
                @{ EntityId = 'sub-1'; EntityType = 'Subscription'; Platform = 'Azure'; Observations = @() }
                @{
                    EntityId = 'rg-new'; EntityType = 'AzureResource'; Platform = 'Azure'
                    Observations = @(@{ Severity = 'Critical'; Title = 'Brand-new critical' })
                }
            )
        } | ConvertTo-Json -Depth 10 | Set-Content -Path $currPath -Encoding UTF8

        $drift  = Compare-EntitySnapshots -Previous $prevPath -Current $currPath
        $result = Get-NewCriticalFindings -DriftResult $drift
        @($result).Count | Should -Be 1
        $result[0].EntityId | Should -Be 'rg-new'
        $result[0].ChangeKind | Should -Be 'New'
    }

    It 'second run with same standing critical does not trigger a new finding' {
        $tmp  = Join-Path $TestDrive 'diff-standing'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $prevPath = Join-Path $tmp 'prev.json'
        $currPath = Join-Path $tmp 'curr.json'

        $snapshot = @{
            SchemaVersion = '3.0'
            Entities      = @(
                @{
                    EntityId = 'rg-old'; EntityType = 'AzureResource'; Platform = 'Azure'
                    Observations = @(@{ Severity = 'Critical'; Title = 'Old critical'; Id = 'obs-1'; Provenance = @{ RunId = 'r1'; Timestamp = '2026-01-01T00:00:00Z'; RawRecordRef = 'x' } })
                }
            )
        }
        $snapshot | ConvertTo-Json -Depth 10 | Set-Content -Path $prevPath -Encoding UTF8
        # Current is identical except volatile provenance fields
        $snapshot2 = @{
            SchemaVersion = '3.0'
            Entities      = @(
                @{
                    EntityId = 'rg-old'; EntityType = 'AzureResource'; Platform = 'Azure'
                    Observations = @(@{ Severity = 'Critical'; Title = 'Old critical'; Id = 'obs-2'; Provenance = @{ RunId = 'r2'; Timestamp = '2026-02-01T00:00:00Z'; RawRecordRef = 'y' } })
                }
            )
        }
        $snapshot2 | ConvertTo-Json -Depth 10 | Set-Content -Path $currPath -Encoding UTF8

        $drift  = Compare-EntitySnapshots -Previous $prevPath -Current $currPath
        $result = Get-NewCriticalFindings -DriftResult $drift
        # Entity is Unchanged (volatile fields ignored) -- no new findings
        @($result).Count | Should -Be 0
    }
}
