#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\..\modules\shared\Sanitize.ps1"
    . "$PSScriptRoot\..\..\modules\shared\EntityStore.ps1"
}

Describe 'EntityStore.SpillToDisk sanitizes JSON before writing' {
    It 'strips Bearer tokens from spill files via Remove-Credentials' {
        $outputPath = Join-Path $TestDrive 'entitystore-sanitize'
        $null = New-Item -ItemType Directory -Path $outputPath -Force

        $store = [EntityStore]::new(1, $outputPath)

        $store.MergeEntityMetadata([pscustomobject]@{
            EntityId         = 'vm-1'
            EntityType       = 'microsoft.compute/virtualmachines'
            Platform         = 'azure'
            WorstSeverity    = 'High'
            CompliantCount   = 0
            NonCompliantCount = 1
            Sources          = @('toolA')
            Observations     = @()
        })
        $store.AddFinding([pscustomobject]@{
            Source     = 'toolA'
            EntityId  = 'vm-1'
            EntityType = 'microsoft.compute/virtualmachines'
            Platform  = 'azure'
            Title     = 'Bearer eyJfake.token.value'
            Severity  = 'High'
            Compliant = $false
        })

        # Trigger spill (threshold is 1)
        $store.MergeEntityMetadata([pscustomobject]@{
            EntityId         = 'vm-2'
            EntityType       = 'microsoft.compute/virtualmachines'
            Platform         = 'azure'
            WorstSeverity    = 'Low'
            CompliantCount   = 1
            NonCompliantCount = 0
            Sources          = @('toolB')
            Observations     = @()
        })

        $entitiesFile = Join-Path $outputPath 'entities-partial-0.json'
        $findingsFile = Join-Path $outputPath 'findings-partial-0.json'

        Test-Path $entitiesFile | Should -BeTrue
        Test-Path $findingsFile | Should -BeTrue

        $entitiesContent = Get-Content $entitiesFile -Raw
        $findingsContent = Get-Content $findingsFile -Raw

        $entitiesContent | Should -Not -Match 'eyJfake\.token\.value'
        $findingsContent | Should -Not -Match 'eyJfake\.token\.value'
        $findingsContent | Should -Match '\[REDACTED\]'
    }
}
