#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\..\modules\shared\EntityStore.ps1"
}

Describe 'EntityStore spill disk-write sanitization' {
    It 'removes Bearer tokens from entity and finding spill files' {
        $token = 'Bearer eyJhbGciOiJIUzI1NiJ9.fake_payload.fake_sig'
        $outputPath = Join-Path $TestDrive 'entitystore-sanitize'
        $null = New-Item -ItemType Directory -Path $outputPath -Force

        $store = [EntityStore]::new(1, $outputPath)

        $store.MergeEntityMetadata([pscustomobject]@{
            EntityId          = "vm-with-$token"
            EntityType        = 'microsoft.compute/virtualmachines'
            Platform          = 'azure'
            WorstSeverity     = 'High'
            CompliantCount    = 0
            NonCompliantCount = 1
            Sources           = @('toolA')
            Observations      = @()
        })
        $store.AddFinding([pscustomobject]@{
            Source     = 'toolA'
            EntityId   = "vm-with-$token"
            EntityType = 'microsoft.compute/virtualmachines'
            Platform   = 'azure'
            Title      = "Synthetic token $token"
            Severity   = 'High'
            Compliant  = $false
        })

        $store.MergeEntityMetadata([pscustomobject]@{
            EntityId          = 'vm-2'
            EntityType        = 'microsoft.compute/virtualmachines'
            Platform          = 'azure'
            WorstSeverity     = 'Low'
            CompliantCount    = 1
            NonCompliantCount = 0
            Sources           = @('toolB')
            Observations      = @()
        })

        $entitiesContent = Get-Content -Path (Join-Path $outputPath 'entities-partial-0.json') -Raw
        $findingsContent = Get-Content -Path (Join-Path $outputPath 'findings-partial-0.json') -Raw

        $entitiesContent | Should -Not -Match [regex]::Escape($token)
        $findingsContent | Should -Not -Match [regex]::Escape($token)
        $entitiesContent | Should -Match 'Bearer \[REDACTED\]'
        $findingsContent | Should -Match 'Bearer \[REDACTED\]'
    }
}
