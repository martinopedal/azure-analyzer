#Requires -Version 7.4

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
}

Describe 'New-FindingRow' {
    It 'creates a finding with required fields and defaults' {
        $finding = New-FindingRow `
            -Id 'f-001' `
            -Source 'azqr' `
            -EntityId '/subscriptions/abc12345-6789-4abc-8def-1234567890ab/resourcegroups/rg/providers/microsoft.storage/storageaccounts/foo' `
            -EntityType 'AzureResource' `
            -Title 'Test' `
            -Compliant $false `
            -ProvenanceRunId 'azqr-run-1'

        $finding.SchemaVersion | Should -Be '2.0'
        $finding.Platform | Should -Be 'Azure'
        $finding.Provenance.RunId | Should -Be 'azqr-run-1'
    }

    It 'returns null when required fields are missing' {
        $row = New-FindingRow -Id '' -Source 'azqr' -EntityId 'x' -EntityType 'AzureResource' -Title 'x' -Compliant $true -ProvenanceRunId 'run'
        $row | Should -BeNullOrEmpty
    }
}

Describe 'New-EntityStub' {
    It 'creates an entity stub with empty observations' {
        $entity = New-EntityStub `
            -CanonicalId '/subscriptions/abc12345-6789-4abc-8def-1234567890ab/resourcegroups/rg/providers/microsoft.storage/storageaccounts/foo' `
            -EntityType 'AzureResource'

        $entity.EntityId | Should -Match '/subscriptions/'
        $entity.Platform | Should -Be 'Azure'
        $entity.Observations | Should -BeNullOrEmpty
    }
}

Describe 'Test-FindingRow' {
    It 'returns true for valid finding rows' {
        $finding = New-FindingRow `
            -Id 'f-002' `
            -Source 'psrule' `
            -EntityId '/subscriptions/abc12345-6789-4abc-8def-1234567890ab/resourcegroups/rg/providers/microsoft.storage/storageaccounts/foo' `
            -EntityType 'AzureResource' `
            -Title 'Valid' `
            -Compliant $true `
            -ProvenanceRunId 'psrule-run-1'

        $errors = @()
        (Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)) | Should -BeTrue
        $errors | Should -BeNullOrEmpty
    }

    It 'returns false with errors for missing required fields' {
        # Build a finding missing EntityId to test validation
        $finding = [PSCustomObject]@{
            Id               = 'f-003'
            Source           = 'azqr'
            EntityType       = 'AzureResource'
            Title            = 'Invalid'
            Compliant        = $false
            SchemaVersion    = '2.0'
            Platform         = 'Azure'
            Provenance       = [PSCustomObject]@{ RunId = 'azqr-run-2'; Source = 'azqr'; Timestamp = (Get-Date).ToUniversalTime().ToString('o') }
        }

        $errors = @()
        (Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)) | Should -BeFalse
        ($errors -join '; ') | Should -Match 'EntityId'
    }

    It 'returns false when Compliant is null' {
        $finding = [PSCustomObject]@{
            Id               = 'f-004'
            Source           = 'azqr'
            EntityId         = '/subscriptions/abc12345-6789-4abc-8def-1234567890ab/resourcegroups/rg/providers/microsoft.storage/storageaccounts/foo'
            EntityType       = 'AzureResource'
            Title            = 'Invalid'
            Compliant        = $null
            SchemaVersion    = '2.0'
            Platform         = 'Azure'
            Provenance       = [PSCustomObject]@{ RunId = 'azqr-run-3'; Source = 'azqr'; Timestamp = (Get-Date).ToUniversalTime().ToString('o') }
        }

        $errors = @()
        (Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)) | Should -BeFalse
        ($errors -join '; ') | Should -Match "Compliant must be a boolean value, got 'null'"
    }
}
