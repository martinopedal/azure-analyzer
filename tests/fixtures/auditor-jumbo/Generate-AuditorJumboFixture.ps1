# Generate auditor-jumbo fixture with 250 findings (scaled from auditor-small)
# Usage: .\Generate-AuditorJumboFixture.ps1

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$sourcePath = Join-Path $PSScriptRoot '..' 'auditor-small'
$targetPath = $PSScriptRoot

# Load auditor-small fixtures
$smallResults = Get-Content (Join-Path $sourcePath 'results.json') -Raw | ConvertFrom-Json
$smallEntities = Get-Content (Join-Path $sourcePath 'entities.json') -Raw | ConvertFrom-Json
$smallManifest = Get-Content (Join-Path $sourcePath 'report-manifest.json') -Raw | ConvertFrom-Json
$smallTriage = Get-Content (Join-Path $sourcePath 'triage.json') -Raw | ConvertFrom-Json

# Scale to 250 findings (50x multiplier from auditor-small's 5 findings)
$multiplier = 50
$jumboResults = @()
$jumboEntities = @{}
$jumboTriage = @()

# Replicate findings with unique IDs
foreach ($i in 1..$multiplier) {
    foreach ($finding in $smallResults) {
        $newFinding = $finding.PSObject.Copy()
        $originalId = $finding.FindingId
        $newFinding.FindingId = "F-$($i)-$($originalId)"
        
        # Vary subscription and resource group
        $subIndex = [Math]::Floor(($i - 1) / 5)
        $rgIndex = ($i - 1) % 5
        $entityId = $finding.EntityId -replace 'test-sub', "sub-$subIndex" -replace 'rg-test', "rg-$rgIndex"
        $newFinding.EntityId = $entityId
        
        $jumboResults += $newFinding
        
        # Add entity if not already present
        if (-not $jumboEntities.ContainsKey($entityId)) {
            $originalEntity = $smallEntities.($finding.EntityId)
            if ($originalEntity) {
                $newEntity = $originalEntity.PSObject.Copy()
                $newEntity.displayName = "$($originalEntity.displayName)-$i"
                $jumboEntities[$entityId] = $newEntity
            }
        }
    }
}

# Add subscriptions and tenant to entities
$jumboEntities['tenant:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'] = $smallEntities.'tenant:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'

foreach ($subIndex in 0..9) {
    $subId = "/subscriptions/sub-$subIndex"
    $jumboEntities[$subId] = @{
        entityType = 'Subscription'
        displayName = "Subscription $subIndex"
        properties = @{ subscriptionId = "sub-$subIndex" }
    }
}

# Replicate triage entries
foreach ($i in 1..$multiplier) {
    foreach ($entry in $smallTriage) {
        $newEntry = $entry.PSObject.Copy()
        $newEntry.FindingId = "F-$i-$($entry.FindingId)"
        $jumboTriage += $newEntry
    }
}

# Write jumbo fixtures
$jumboResults | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $targetPath 'results.json') -NoNewline
$jumboEntities | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $targetPath 'entities.json') -NoNewline
$smallManifest | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $targetPath 'report-manifest.json') -NoNewline
$jumboTriage | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $targetPath 'triage.json') -NoNewline

Write-Host "✓ Generated auditor-jumbo fixture with $($jumboResults.Count) findings"
