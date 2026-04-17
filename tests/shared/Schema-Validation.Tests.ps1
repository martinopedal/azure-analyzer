#Requires -Version 7.4
<#
.SYNOPSIS
    Schema validation tests for Issue #99.
.DESCRIPTION
    Tests for New-FindingRow factory validation and tracking.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\modules\shared\Schema.ps1"
    . "$PSScriptRoot\..\..\modules\shared\Canonicalize.ps1"
    . "$PSScriptRoot\..\..\modules\shared\Sanitize.ps1"
}

Describe 'New-FindingRow validation' {
    It 'returns a valid row for correct inputs' {
        $row = New-FindingRow `
            -Id 'f-001' `
            -Source 'azqr' `
            -EntityId '/subscriptions/abc12345-6789-4abc-8def-1234567890ab/resourcegroups/rg/providers/microsoft.storage/storageaccounts/foo' `
            -EntityType 'AzureResource' `
            -Title 'Test' `
            -Compliant $true `
            -ProvenanceRunId 'azqr-run-1'

        $row | Should -Not -BeNullOrEmpty
        $row.Id | Should -Be 'f-001'
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

    It 'logs validation failures' {
        Reset-SchemaValidationFailures

        $null = New-FindingRow `
            -Id 'f-fail' `
            -Source 'test-source' `
            -EntityId '/SUBSCRIPTIONS/TEST' `
            -EntityType 'AzureResource' `
            -Title 'Test' `
            -Compliant $true `
            -ProvenanceRunId 'run-1' `
            -WarningAction SilentlyContinue

        $failures = Get-SchemaValidationFailures
        $failures.Count | Should -BeGreaterThan 0
        $failures[0].Source | Should -Be 'test-source'
    }

    It 'can reset validation failures' {
        Reset-SchemaValidationFailures
        $failures = Get-SchemaValidationFailures
        $failures.Count | Should -Be 0
    }
}
