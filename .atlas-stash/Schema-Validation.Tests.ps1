#Requires -Version 7.4
<#
.SYNOPSIS
    Schema validation comprehensive tests for Issue #99.
.DESCRIPTION
    Tests for Test-FindingRow validation function and New-FindingRow factory integration.
    Covers v2/v3 schema validation, strict mode, error aggregation, credential sanitization,
    and validation failure tracking.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\modules\shared\Schema.ps1"
    . "$PSScriptRoot\..\..\modules\shared\Canonicalize.ps1"
    . "$PSScriptRoot\..\..\modules\shared\Sanitize.ps1"
}

Describe 'Test-FindingRow validation' {
    Context 'Valid finding rows' {
        It 'returns true for a valid finding row' {
            $finding = New-FindingRow `
                -Id 'f-001' `
                -Source 'azqr' `
                -EntityId '/subscriptions/abc12345-6789-4abc-8def-1234567890ab/resourcegroups/rg/providers/microsoft.storage/storageaccounts/foo' `
                -EntityType 'AzureResource' `
                -Title 'Test' `
                -Compliant $true `
                -ProvenanceRunId 'azqr-run-1'

            $errors = @()
            (Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)) | Should -BeTrue
            $errors | Should -BeNullOrEmpty
        }

        It 'returns true when optional Severity is valid' {
            $finding = New-FindingRow `
                -Id 'f-002' `
                -Source 'psrule' `
                -EntityId '/subscriptions/abc12345-6789-4abc-8def-1234567890ab/resourcegroups/rg/providers/microsoft.storage/storageaccounts/foo' `
                -EntityType 'AzureResource' `
                -Title 'Test' `
                -Compliant $true `
                -Severity 'High' `
                -ProvenanceRunId 'psrule-run-1'

            $errors = @()
            (Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)) | Should -BeTrue
            $errors | Should -BeNullOrEmpty
        }
    }

    Context 'Missing required fields' {
        It 'returns false when Id is missing' {
            $finding = [PSCustomObject]@{
                Source        = 'test'
                EntityId      = 'test/entity'
                EntityType    = 'AzureResource'
                Title         = 'Test'
                Compliant     = $true
                SchemaVersion = '2.0'
                Platform      = 'Azure'
                Provenance    = [PSCustomObject]@{ RunId = 'run-1'; Source = 'test'; Timestamp = (Get-Date).ToUniversalTime().ToString('o') }
            }

            $errors = @()
            (Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)) | Should -BeFalse
            ($errors -join '; ') | Should -Match 'Id'
        }

        It 'returns false when Source is missing' {
            $finding = [PSCustomObject]@{
                Id            = 'f-001'
                EntityId      = 'test/entity'
                EntityType    = 'AzureResource'
                Title         = 'Test'
                Compliant     = $true
                SchemaVersion = '2.0'
                Platform      = 'Azure'
                Provenance    = [PSCustomObject]@{ RunId = 'run-1'; Source = 'test'; Timestamp = (Get-Date).ToUniversalTime().ToString('o') }
            }

            $errors = @()
            (Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)) | Should -BeFalse
            ($errors -join '; ') | Should -Match 'Source'
        }

        It 'returns false when EntityId is empty' {
            $finding = [PSCustomObject]@{
                Id            = 'f-001'
                Source        = 'test'
                EntityId      = ''
                EntityType    = 'AzureResource'
                Title         = 'Test'
                Compliant     = $true
                SchemaVersion = '2.0'
                Platform      = 'Azure'
                Provenance    = [PSCustomObject]@{ RunId = 'run-1'; Source = 'test'; Timestamp = (Get-Date).ToUniversalTime().ToString('o') }
            }

            $errors = @()
            (Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)) | Should -BeFalse
            ($errors -join '; ') | Should -Match 'EntityId'
        }

        It 'returns false when Compliant is missing' {
            $finding = [PSCustomObject]@{
                Id            = 'f-001'
                Source        = 'test'
                EntityId      = 'test/entity'
                EntityType    = 'AzureResource'
                Title         = 'Test'
                SchemaVersion = '2.0'
                Platform      = 'Azure'
                Provenance    = [PSCustomObject]@{ RunId = 'run-1'; Source = 'test'; Timestamp = (Get-Date).ToUniversalTime().ToString('o') }
            }

            $errors = @()
            (Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)) | Should -BeFalse
            ($errors -join '; ') | Should -Match 'Compliant'
        }

        It 'returns false when Provenance.RunId is missing' {
            $finding = [PSCustomObject]@{
                Id            = 'f-001'
                Source        = 'test'
                EntityId      = 'test/entity'
                EntityType    = 'AzureResource'
                Title         = 'Test'
                Compliant     = $true
                SchemaVersion = '2.0'
                Platform      = 'Azure'
                Provenance    = [PSCustomObject]@{ Source = 'test'; Timestamp = (Get-Date).ToUniversalTime().ToString('o') }
            }

            $errors = @()
            (Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)) | Should -BeFalse
            ($errors -join '; ') | Should -Match 'Provenance.RunId'
        }
    }

    Context 'Invalid field values' {
        It 'returns false when Compliant is not a boolean' {
            $finding = [PSCustomObject]@{
                Id            = 'f-001'
                Source        = 'test'
                EntityId      = 'test/entity'
                EntityType    = 'AzureResource'
                Title         = 'Test'
                Compliant     = 'not-a-bool'
                SchemaVersion = '2.0'
                Platform      = 'Azure'
                Provenance    = [PSCustomObject]@{ RunId = 'run-1'; Source = 'test'; Timestamp = (Get-Date).ToUniversalTime().ToString('o') }
            }

            $errors = @()
            (Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)) | Should -BeFalse
            ($errors -join '; ') | Should -Match 'boolean'
        }

        It 'returns false and lists valid severity levels when Severity is invalid' {
            $finding = [PSCustomObject]@{
                Id            = 'f-001'
                Source        = 'test'
                EntityId      = 'test/entity'
                EntityType    = 'AzureResource'
                Title         = 'Test'
                Compliant     = $true
                Severity      = 'InvalidSeverity'
                SchemaVersion = '2.0'
                Platform      = 'Azure'
                Provenance    = [PSCustomObject]@{ RunId = 'run-1'; Source = 'test'; Timestamp = (Get-Date).ToUniversalTime().ToString('o') }
            }

            $errors = @()
            (Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)) | Should -BeFalse
            ($errors -join '; ') | Should -Match 'Severity'
        }

        It 'returns false and lists valid entity types when EntityType is invalid' {
            $finding = [PSCustomObject]@{
                Id            = 'f-001'
                Source        = 'test'
                EntityId      = 'test/entity'
                EntityType    = 'InvalidType'
                Title         = 'Test'
                Compliant     = $true
                SchemaVersion = '2.0'
                Platform      = 'Azure'
                Provenance    = [PSCustomObject]@{ RunId = 'run-1'; Source = 'test'; Timestamp = (Get-Date).ToUniversalTime().ToString('o') }
            }

            $errors = @()
            (Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)) | Should -BeFalse
            ($errors -join '; ') | Should -Match 'EntityType'
        }

        It 'returns false when Platform is invalid' {
            $finding = [PSCustomObject]@{
                Id            = 'f-001'
                Source        = 'test'
                EntityId      = 'test/entity'
                EntityType    = 'AzureResource'
                Title         = 'Test'
                Compliant     = $true
                Platform      = 'InvalidPlatform'
                SchemaVersion = '2.0'
                Provenance    = [PSCustomObject]@{ RunId = 'run-1'; Source = 'test'; Timestamp = (Get-Date).ToUniversalTime().ToString('o') }
            }

            $errors = @()
            (Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)) | Should -BeFalse
            ($errors -join '; ') | Should -Match 'Platform'
        }
    }

    Context 'Strict mode' {
        It 'throws exception when validation fails in strict mode' {
            $finding = [PSCustomObject]@{
                Id            = 'f-001'
                Source        = 'test'
                EntityId      = ''
                EntityType    = 'AzureResource'
                Title         = 'Test'
                Compliant     = $true
                SchemaVersion = '2.0'
                Platform      = 'Azure'
                Provenance    = [PSCustomObject]@{ RunId = 'run-1'; Source = 'test'; Timestamp = (Get-Date).ToUniversalTime().ToString('o') }
            }

            { Test-FindingRow -Finding $finding -Strict } | Should -Throw
        }

        It 'does not throw when validation passes in strict mode' {
            $finding = New-FindingRow `
                -Id 'f-001' `
                -Source 'azqr' `
                -EntityId '/subscriptions/abc12345-6789-4abc-8def-1234567890ab/resourcegroups/rg/providers/microsoft.storage/storageaccounts/foo' `
                -EntityType 'AzureResource' `
                -Title 'Test' `
                -Compliant $true `
                -ProvenanceRunId 'azqr-run-1'

            { Test-FindingRow -Finding $finding -Strict } | Should -Not -Throw
        }
    }

    Context 'Aggregated errors' {
        It 'returns all validation errors in a single call' {
            $finding = [PSCustomObject]@{
                Id            = ''
                Source        = ''
                EntityId      = ''
                EntityType    = 'AzureResource'
                Title         = 'Test'
                Compliant     = $true
                SchemaVersion = '2.0'
                Platform      = 'Azure'
                Provenance    = [PSCustomObject]@{ Source = 'test'; Timestamp = (Get-Date).ToUniversalTime().ToString('o') }
            }

            $errors = @()
            (Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)) | Should -BeFalse
            $errors.Count | Should -BeGreaterThan 2
            ($errors -join '; ') | Should -Match 'Id'
            ($errors -join '; ') | Should -Match 'Source'
            ($errors -join '; ') | Should -Match 'EntityId'
        }
    }
}

Describe 'New-FindingRow validation integration' {
    Context 'Factory validation' {
        It 'returns a valid row when all parameters are correct' {
            $row = New-FindingRow `
                -Id 'f-test' `
                -Source 'test-tool' `
                -EntityId '/subscriptions/abc12345-6789-4abc-8def-1234567890ab/resourcegroups/test/providers/microsoft.storage/storageaccounts/foo' `
                -EntityType 'AzureResource' `
                -Title 'Test' `
                -Compliant $true `
                -ProvenanceRunId 'run-1'

            $row | Should -Not -BeNullOrEmpty
            $row.Id | Should -Be 'f-test'
            $row.Source | Should -Be 'test-tool'
            $row.EntityType | Should -Be 'AzureResource'
        }

        It 'validates EntityId canonicalization' {
            # Non-canonical EntityId should return null
            $row = New-FindingRow `
                -Id 'f-test' `
                -Source 'test-tool' `
                -EntityId '/Subscriptions/ABC12345-6789-4ABC-8DEF-1234567890AB/ResourceGroups/TEST/providers/Microsoft.Storage/storageAccounts/foo' `
                -EntityType 'AzureResource' `
                -Title 'Test' `
                -Compliant $true `
                -ProvenanceRunId 'run-1' `
                -WarningAction SilentlyContinue

            # The row should be null because validation failed
            $row | Should -BeNullOrEmpty
        }
    }

    Context 'Sanitization of error messages' {
        It 'sanitizes credentials in validation error messages' {
            $finding = [PSCustomObject]@{
                Id            = 'f-001'
                Source        = 'test'
                EntityId      = 'https://user:password@example.com/resource'
                EntityType    = 'AzureResource'
                Title         = 'Test'
                Compliant     = $true
                SchemaVersion = '2.0'
                Platform      = 'Azure'
                Provenance    = [PSCustomObject]@{ RunId = 'run-1'; Source = 'test'; Timestamp = (Get-Date).ToUniversalTime().ToString('o') }
            }

            $errors = @()
            Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors) | Out-Null
            ($errors -join '; ') | Should -Not -Match 'password'
        }
    }

    Context 'Validation failure tracking' {
        It 'tracks validation failures via Get-SchemaValidationFailures' {
            Reset-SchemaValidationFailures

            # Create a finding with non-canonical ID that will fail validation
            $null = New-FindingRow `
                -Id 'f-fail' `
                -Source 'test-source' `
                -EntityId '/Subscriptions/TEST' `
                -EntityType 'AzureResource' `
                -Title 'Test' `
                -Compliant $true `
                -ProvenanceRunId 'run-1' `
                -WarningAction SilentlyContinue

            $failures = Get-SchemaValidationFailures
            $failures.Count | Should -BeGreaterThan 0
            $failures[0].Source | Should -Be 'test-source'
        }

        It 'resets validation failures via Reset-SchemaValidationFailures' {
            Reset-SchemaValidationFailures
            $failures = Get-SchemaValidationFailures
            $failures.Count | Should -Be 0
        }
    }
}

Describe 'Existing Test-FindingRow compatibility' {
    It 'maintains backward compatibility with existing tests' {
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

    It 'detects non-canonical IDs and returns null' {
        Reset-SchemaValidationFailures

        # Manually construct a finding with non-canonical EntityId
        $finding = [PSCustomObject]@{
            Id               = 'f-003'
            Source           = 'azqr'
            EntityId         = '/Subscriptions/ABC12345-6789-4ABC-8DEF-1234567890AB/ResourceGroups/rg/providers/Microsoft.Storage/storageAccounts/foo'
            EntityType       = 'AzureResource'
            Title            = 'Invalid'
            Compliant        = $false
            SchemaVersion    = '2.0'
            Platform         = 'Azure'
            Provenance       = [PSCustomObject]@{ RunId = 'azqr-run-2'; Source = 'azqr'; Timestamp = (Get-Date).ToUniversalTime().ToString('o') }
        }

        # Test validation
        $errors = @()
        $result = Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)
        $result | Should -BeFalse
        ($errors -join '; ') | Should -Match 'canonical'
    }
}
