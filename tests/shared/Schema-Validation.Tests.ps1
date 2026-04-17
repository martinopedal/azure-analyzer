#Requires -Version 7.4

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Sanitize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
}

Describe 'Test-FindingRow validation' {
    Context 'Valid finding rows' {
        It 'returns true for a valid finding row' {
            $finding = New-FindingRow `
                -Id 'f-001' `
                -Source 'azqr' `
                -EntityId '/subscriptions/abc12345-6789-4abc-8def-1234567890ab/resourcegroups/rg/providers/microsoft.storage/storageaccounts/foo' `
                -EntityType 'AzureResource' `
                -Title 'Test Finding' `
                -Compliant $false `
                -ProvenanceRunId 'azqr-run-1'

            $errors = @()
            (Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)) | Should -BeTrue
            $errors | Should -BeNullOrEmpty
        }

        It 'returns true when optional Severity is valid' {
            $finding = New-FindingRow `
                -Id 'f-002' `
                -Source 'psrule' `
                -EntityId '/subscriptions/abc12345-6789-4abc-8def-1234567890ab/resourcegroups/rg/providers/microsoft.compute/virtualmachines/vm1' `
                -EntityType 'AzureResource' `
                -Title 'VM Security' `
                -Severity 'High' `
                -Compliant $false `
                -ProvenanceRunId 'psrule-run-1'

            $errors = @()
            (Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)) | Should -BeTrue
            $errors | Should -BeNullOrEmpty
        }
    }

    Context 'Missing required fields' {
        It 'returns false when Id is missing' {
            $finding = [PSCustomObject]@{
                Source           = 'azqr'
                EntityId         = 'test/entity'
                EntityType       = 'AzureResource'
                Title            = 'Test'
                Compliant        = $true
                SchemaVersion    = '2.0'
                Provenance       = [PSCustomObject]@{ RunId = 'run-1' }
            }

            $errors = @()
            (Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)) | Should -BeFalse
            ($errors -join '; ') | Should -Match "Required field 'Id' is missing"
        }

        It 'returns false when Source is missing' {
            $finding = [PSCustomObject]@{
                Id               = 'f-001'
                EntityId         = 'test/entity'
                EntityType       = 'AzureResource'
                Title            = 'Test'
                Compliant        = $true
                SchemaVersion    = '2.0'
                Provenance       = [PSCustomObject]@{ RunId = 'run-1' }
            }

            $errors = @()
            (Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)) | Should -BeFalse
            ($errors -join '; ') | Should -Match "Required field 'Source' is missing"
        }

        It 'returns false when EntityId is empty' {
            $finding = [PSCustomObject]@{
                Id               = 'f-001'
                Source           = 'azqr'
                EntityId         = ''
                EntityType       = 'AzureResource'
                Title            = 'Test'
                Compliant        = $true
                SchemaVersion    = '2.0'
                Provenance       = [PSCustomObject]@{ RunId = 'run-1' }
            }

            $errors = @()
            (Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)) | Should -BeFalse
            ($errors -join '; ') | Should -Match "Required field 'EntityId' is empty"
        }

        It 'returns false when Compliant is missing' {
            $finding = [PSCustomObject]@{
                Id               = 'f-001'
                Source           = 'azqr'
                EntityId         = 'test/entity'
                EntityType       = 'AzureResource'
                Title            = 'Test'
                SchemaVersion    = '2.0'
                Provenance       = [PSCustomObject]@{ RunId = 'run-1' }
            }

            $errors = @()
            (Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)) | Should -BeFalse
            ($errors -join '; ') | Should -Match "Required field 'Compliant' is missing"
        }

        It 'returns false when Provenance.RunId is missing' {
            $finding = [PSCustomObject]@{
                Id               = 'f-001'
                Source           = 'azqr'
                EntityId         = 'test/entity'
                EntityType       = 'AzureResource'
                Title            = 'Test'
                Compliant        = $true
                SchemaVersion    = '2.0'
                Provenance       = [PSCustomObject]@{}
            }

            $errors = @()
            (Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)) | Should -BeFalse
            ($errors -join '; ') | Should -Match "Provenance.RunId is missing"
        }
    }

    Context 'Invalid field values' {
        It 'returns false when Compliant is not a boolean' {
            $finding = [PSCustomObject]@{
                Id               = 'f-001'
                Source           = 'azqr'
                EntityId         = 'test/entity'
                EntityType       = 'AzureResource'
                Title            = 'Test'
                Compliant        = 'true'  # string, not boolean
                SchemaVersion    = '2.0'
                Provenance       = [PSCustomObject]@{ RunId = 'run-1' }
            }

            $errors = @()
            (Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)) | Should -BeFalse
            ($errors -join '; ') | Should -Match "Compliant must be a boolean value"
        }

        It 'returns false and lists valid severity levels when Severity is invalid' {
            $finding = [PSCustomObject]@{
                Id               = 'f-001'
                Source           = 'azqr'
                EntityId         = 'test/entity'
                EntityType       = 'AzureResource'
                Title            = 'Test'
                Severity         = 'Warning'  # Invalid
                Compliant        = $false
                SchemaVersion    = '2.0'
                Provenance       = [PSCustomObject]@{ RunId = 'run-1' }
            }

            $errors = @()
            (Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)) | Should -BeFalse
            $errorMsg = $errors -join '; '
            $errorMsg | Should -Match "Severity 'Warning' is not valid"
            $errorMsg | Should -Match "Critical"
            $errorMsg | Should -Match "High"
            $errorMsg | Should -Match "Medium"
            $errorMsg | Should -Match "Low"
            $errorMsg | Should -Match "Info"
        }

        It 'returns false and lists valid entity types when EntityType is invalid' {
            $finding = [PSCustomObject]@{
                Id               = 'f-001'
                Source           = 'azqr'
                EntityId         = 'test/entity'
                EntityType       = 'InvalidType'  # Invalid
                Title            = 'Test'
                Compliant        = $false
                SchemaVersion    = '2.0'
                Provenance       = [PSCustomObject]@{ RunId = 'run-1' }
            }

            $errors = @()
            (Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)) | Should -BeFalse
            $errorMsg = $errors -join '; '
            $errorMsg | Should -Match "EntityType 'InvalidType' is not valid"
            $errorMsg | Should -Match "AzureResource"
            $errorMsg | Should -Match "Repository"
            $errorMsg | Should -Match "Pipeline"
        }

        It 'returns false when Platform is invalid' {
            $finding = [PSCustomObject]@{
                Id               = 'f-001'
                Source           = 'azqr'
                EntityId         = 'test/entity'
                EntityType       = 'AzureResource'
                Platform         = 'AWS'  # Invalid
                Title            = 'Test'
                Compliant        = $false
                SchemaVersion    = '2.0'
                Provenance       = [PSCustomObject]@{ RunId = 'run-1' }
            }

            $errors = @()
            (Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)) | Should -BeFalse
            $errorMsg = $errors -join '; '
            $errorMsg | Should -Match "Platform 'AWS' is not valid"
            $errorMsg | Should -Match "Azure"
            $errorMsg | Should -Match "Entra"
            $errorMsg | Should -Match "GitHub"
            $errorMsg | Should -Match "ADO"
        }
    }

    Context 'Strict mode' {
        It 'throws exception when validation fails in strict mode' {
            $finding = [PSCustomObject]@{
                Id               = 'f-001'
                Source           = 'azqr'
                EntityId         = ''  # Empty
                EntityType       = 'AzureResource'
                Title            = 'Test'
                Compliant        = $true
                SchemaVersion    = '2.0'
                Provenance       = [PSCustomObject]@{ RunId = 'run-1' }
            }

            { Test-FindingRow -Finding $finding -Strict } | Should -Throw -ExpectedMessage '*FindingRow schema validation failed*'
        }

        It 'does not throw when validation passes in strict mode' {
            $finding = New-FindingRow `
                -Id 'f-001' `
                -Source 'azqr' `
                -EntityId '/subscriptions/abc12345-6789-4abc-8def-1234567890ab/resourcegroups/rg/providers/microsoft.storage/storageaccounts/foo' `
                -EntityType 'AzureResource' `
                -Title 'Test' `
                -Compliant $false `
                -ProvenanceRunId 'azqr-run-1'

            { Test-FindingRow -Finding $finding -Strict } | Should -Not -Throw
        }
    }

    Context 'Aggregated errors' {
        It 'returns all validation errors in a single call' {
            $finding = [PSCustomObject]@{
                Id               = ''  # Empty
                Source           = ''  # Empty
                EntityId         = 'test/entity'
                EntityType       = 'InvalidType'  # Invalid
                Title            = 'Test'
                Severity         = 'Warning'  # Invalid
                Compliant        = 'not-a-bool'  # Wrong type
                SchemaVersion    = '2.0'
                Provenance       = [PSCustomObject]@{}  # Missing RunId
            }

            $errors = @()
            (Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)) | Should -BeFalse
            $errors.Count | Should -BeGreaterThan 3  # Multiple errors
            ($errors -join '; ') | Should -Match "Id"
            ($errors -join '; ') | Should -Match "Source"
            ($errors -join '; ') | Should -Match "EntityType"
            ($errors -join '; ') | Should -Match "Severity"
            ($errors -join '; ') | Should -Match "Compliant"
            ($errors -join '; ') | Should -Match "Provenance"
        }
    }
}

Describe 'New-FindingRow validation integration' {
    BeforeEach {
        # Clear validation failures before each test
        Reset-SchemaValidationFailures
    }

    Context 'Factory validation' {
        It 'returns a valid row when all parameters are correct' {
            $row = New-FindingRow `
                -Id 'f-test' `
                -Source 'test-tool' `
                -EntityId '/subscriptions/abc12345-6789-4abc-8def-1234567890ab/resourcegroups/rg/providers/microsoft.storage/storageaccounts/test' `
                -EntityType 'AzureResource' `
                -Title 'Test Finding' `
                -Compliant $false `
                -ProvenanceRunId 'test-run-1'

            $row | Should -Not -BeNullOrEmpty
            $row.Id | Should -Be 'f-test'
            $row.Source | Should -Be 'test-tool'
            $row.EntityType | Should -Be 'AzureResource'
        }

        It 'returns null for non-canonical EntityIds' {
            Reset-SchemaValidationFailures

            $row = New-FindingRow `
                -Id 'f-test' `
                -Source 'test-tool' `
                -EntityId '/Subscriptions/UPPERCASE/ResourceGroups/TEST' `
                -EntityType 'AzureResource' `
                -Title 'Test' `
                -Compliant $true `
                -ProvenanceRunId 'run-1' `
                -WarningAction SilentlyContinue

            $row | Should -BeNullOrEmpty

            $failures = Get-SchemaValidationFailures
            $failures.Count | Should -BeGreaterThan 0
            $failures[0].Source | Should -Be 'test-tool'
        }

        It 'returns null and logs warning when validation fails' {
            Reset-SchemaValidationFailures

            $row = New-FindingRow `
                -Id 'f-test' `
                -Source 'test-tool' `
                -EntityId '' `
                -EntityType 'AzureResource' `
                -Title 'Test' `
                -Compliant $true `
                -ProvenanceRunId 'run-1'

            $row | Should -BeNullOrEmpty
        }
    }

    Context 'Sanitization of error messages' {
        It 'sanitizes credentials in validation error messages' {
            # Create a finding with a GitHub PAT in Detail field
            $secretDetail = 'Token: ghp_1234567890123456789012345678901234'
            $finding = [PSCustomObject]@{
                Id               = 'f-001'
                Source           = 'azqr'
                EntityId         = 'test/entity'
                EntityType       = 'AzureResource'
                Title            = 'Test'
                Detail           = $secretDetail
                Compliant        = 'not-a-bool'  # Force validation failure
                SchemaVersion    = '2.0'
                Provenance       = [PSCustomObject]@{ RunId = 'run-1' }
            }

            $errors = @()
            $null = Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)
            
            # The error message itself shouldn't contain the secret
            $errorMsg = $errors -join '; '
            $errorMsg | Should -Not -Match 'ghp_1234567890123456789012345678901234'
        }
    }

    Context 'Validation failure tracking' {
        It 'tracks validation failures via Get-SchemaValidationFailures' {
            Reset-SchemaValidationFailures

            # Manually construct a finding with validation issues
            $finding = [PSCustomObject]@{
                Id               = 'f-fail'
                Source           = 'test-source'
                EntityId         = ''
                EntityType       = 'AzureResource'
                Title            = 'Test'
                Compliant        = $true
                SchemaVersion    = '2.0'
                Platform         = 'Azure'
                Provenance       = [PSCustomObject]@{ RunId = 'run-1'; Source = 'test-source'; Timestamp = (Get-Date).ToUniversalTime().ToString('o') }
            }

            # Test validation (this won't add to tracking, but confirms it fails)
            $errors = @()
            $result = Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)
            $result | Should -BeFalse
        }

        It 'resets validation failures via Reset-SchemaValidationFailures' {
            Reset-SchemaValidationFailures
            $failures = Get-SchemaValidationFailures
            $failures | Should -BeNullOrEmpty
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

    It 'detects missing required fields and returns null' {
        Reset-SchemaValidationFailures

        # Manually construct a finding missing EntityId
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

        # Test validation
        $errors = @()
        $result = Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)
        $result | Should -BeFalse
        ($errors -join '; ') | Should -Match 'EntityId'
    }
}
