Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\..\modules\shared\EntityStore.ps1"
}

Describe 'EntityStore spill merge' {
    It 'sums aggregate counters when duplicate entities are merged from spill files' {
        $outputPath = Join-Path $PSScriptRoot '..\..\output-test\entitystore-dedup'
        if (Test-Path $outputPath) {
            Remove-Item -Path $outputPath -Recurse -Force
        }
        $null = New-Item -Path $outputPath -ItemType Directory -Force

        try {
            $store = [EntityStore]::new(1, $outputPath)
            $store.MergeEntityMetadata([pscustomobject]@{
                EntityId         = 'vm-1'
                EntityType       = 'microsoft.compute/virtualmachines'
                Platform         = 'azure'
                WorstSeverity    = 'Low'
                CompliantCount   = 1
                NonCompliantCount = 2
                Sources          = @('toolA')
                Observations     = @()
            })
            $store.AddFinding([pscustomobject]@{
                Source      = 'toolA'
                EntityId    = 'vm-1'
                EntityType  = 'microsoft.compute/virtualmachines'
                Platform    = 'azure'
                Title       = 'test finding'
                Severity    = 'Low'
                Compliant   = $false
            })

            $store.MergeEntityMetadata([pscustomobject]@{
                EntityId         = 'vm-1'
                EntityType       = 'microsoft.compute/virtualmachines'
                Platform         = 'azure'
                WorstSeverity    = 'High'
                CompliantCount   = 3
                NonCompliantCount = 4
                Sources          = @('toolB')
                Observations     = @()
            })

            $entities = $store.GetEntities()
            $entity = @($entities | Where-Object { $_.EntityId -eq 'vm-1' })[0]

            $entity.CompliantCount | Should -Be 4
            $entity.NonCompliantCount | Should -Be 7
            $entity.WorstSeverity | Should -Be 'High'
            $entity.Sources | Should -Contain 'toolA'
            $entity.Sources | Should -Contain 'toolB'
        } finally {
            if ($null -ne $store) {
                $store.CleanupSpillFiles()
            }
            if (Test-Path $outputPath) {
                Remove-Item -Path $outputPath -Recurse -Force
            }
        }
    }
}


Describe 'Merge-FrameworksUnion (Schema 2.2)' {
    It 'deduplicates framework hashtables by (kind, controlId) tuple' {
        $existing = @(
            @{ kind = 'CIS';   controlId = '1.1.1'; version = '1.4.0' },
            @{ kind = 'NIST';  controlId = 'CA-7' }
        )
        $incoming = @(
            @{ kind = 'CIS';   controlId = '1.1.1'; version = '2.0.0' },  # dup
            @{ kind = 'CIS';   controlId = '1.1.2' },
            @{ kind = 'MITRE'; controlId = 'TA0001' }
        )

        $merged = Merge-FrameworksUnion -Existing $existing -Incoming $incoming
        @($merged).Count | Should -Be 4

        $cis111 = @($merged | Where-Object { $_.kind -eq 'CIS' -and $_.controlId -eq '1.1.1' })
        $cis111.Count | Should -Be 1
        # First-occurrence wins: existing version preserved
        $cis111[0].version | Should -Be '1.4.0'
    }

    It 'accepts PSCustomObject entries with kind/controlId properties' {
        $existing = @([pscustomobject]@{ kind = 'CIS'; controlId = '1.1.1' })
        $incoming = @([pscustomobject]@{ kind = 'CIS'; controlId = '1.1.1' })
        $merged = Merge-FrameworksUnion -Existing $existing -Incoming $incoming
        @($merged).Count | Should -Be 1
    }

    It 'skips entries missing kind or controlId rather than crashing' {
        $existing = @(@{ kind = 'CIS'; controlId = '1.1.1' })
        $incoming = @(@{ kind = 'CIS' }, @{ controlId = '1.1.2' }, $null)
        $merged = Merge-FrameworksUnion -Existing $existing -Incoming $incoming
        @($merged).Count | Should -Be 1
    }

    It 'returns empty array when both inputs are empty' {
        $merged = Merge-FrameworksUnion -Existing @() -Incoming @()
        @($merged).Count | Should -Be 0
    }
}

Describe 'Merge-BaselineTagsUnion (Schema 2.2)' {
    It 'deduplicates string tags case-sensitively, preserving order' {
        $merged = Merge-BaselineTagsUnion -Existing @('release:GA','baseline:cis-1.4') -Incoming @('release:GA','release:preview')
        @($merged).Count | Should -Be 3
        $merged[0] | Should -Be 'release:GA'
        $merged[1] | Should -Be 'baseline:cis-1.4'
        $merged[2] | Should -Be 'release:preview'
    }

    It 'treats different-cased tags as distinct (preview != PREVIEW)' {
        $merged = Merge-BaselineTagsUnion -Existing @('release:preview') -Incoming @('release:PREVIEW')
        @($merged).Count | Should -Be 2
    }

    It 'skips null/whitespace tags' {
        $merged = Merge-BaselineTagsUnion -Existing @('a','') -Incoming @($null,'  ','b')
        @($merged).Count | Should -Be 2
        $merged | Should -Contain 'a'
        $merged | Should -Contain 'b'
    }

    It 'returns empty array when both inputs are empty' {
        $merged = Merge-BaselineTagsUnion -Existing @() -Incoming @()
        @($merged).Count | Should -Be 0
    }
}

Describe 'EntityStore Schema 2.2 merge integration' {
    It 'merges Frameworks and BaselineTags when duplicate findings collapse' {
        $storeOutput = Join-Path $PSScriptRoot '..\..\output-test\entitystore-schema22-merge'
        if (-not (Test-Path $storeOutput)) { $null = New-Item -ItemType Directory -Path $storeOutput -Force }
        try {
            $store = [EntityStore]::new(50000, $storeOutput)
            $base = [pscustomobject]@{
                Source      = 'powerpipe'
                EntityId    = '/subscriptions/11111111-1111-1111-1111-111111111111/resourcegroups/rg/providers/microsoft.storage/storageaccounts/st01'
                EntityType  = 'AzureResource'
                Platform    = 'Azure'
                Title       = 'Control A'
                Compliant   = $false
                Severity    = 'High'
                Detail      = 'detail-a'
                Remediation = 'fix-a'
                LearnMoreUrl = ''
                Provenance  = $null
                Frameworks  = @(@{ kind = 'CIS'; controlId = '1.1.1' })
                BaselineTags = @('release:preview')
            }
            $incoming = [pscustomobject]@{
                Source      = 'powerpipe'
                EntityId    = $base.EntityId
                EntityType  = 'AzureResource'
                Platform    = 'Azure'
                Title       = 'Control A'
                Compliant   = $false
                Severity    = 'Medium'
                Detail      = 'detail-b'
                Remediation = 'fix-b'
                LearnMoreUrl = ''
                Provenance  = $null
                Frameworks  = @(@{ kind = 'NIST'; controlId = 'CA-7' }, @{ kind = 'CIS'; controlId = '1.1.1' })
                BaselineTags = @('release:GA')
            }

            $store.AddFinding($base)
            $store.AddFinding($incoming)
            $findings = @($store.GetFindings())

            $findings.Count | Should -Be 1
            @($findings[0].Frameworks).Count | Should -Be 2
            $findings[0].BaselineTags | Should -Contain 'release:preview'
            $findings[0].BaselineTags | Should -Contain 'release:GA'
        } finally {
            if (Test-Path $storeOutput) {
                Remove-Item -Path $storeOutput -Recurse -Force
            }
        }
    }
}
