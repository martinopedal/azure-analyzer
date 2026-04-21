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

        $finding.SchemaVersion | Should -Be '2.2'
        $finding.Platform | Should -Be 'Azure'
        $finding.Provenance.RunId | Should -Be 'azqr-run-1'
    }

    It 'returns null when required fields are missing' {
        $row = New-FindingRow -Id '' -Source 'azqr' -EntityId 'x' -EntityType 'AzureResource' -Title 'x' -Compliant $true -ProvenanceRunId 'run'
        $row | Should -BeNullOrEmpty
    }

    It 'defaults RuleId to empty string when not supplied (back-compat)' {
        $finding = New-FindingRow `
            -Id 'f-ruleid-default' `
            -Source 'azqr' `
            -EntityId '/subscriptions/abc12345-6789-4abc-8def-1234567890ab/resourcegroups/rg/providers/microsoft.storage/storageaccounts/foo' `
            -EntityType 'AzureResource' `
            -Title 'No RuleId here' `
            -Compliant $true `
            -ProvenanceRunId 'azqr-run-default'

        $finding.PSObject.Properties.Match('RuleId').Count | Should -Be 1
        $finding.RuleId | Should -Be ''
    }

    It 'persists RuleId on the row when supplied (v2.1 additive field)' {
        $finding = New-FindingRow `
            -Id 'f-ruleid' `
            -Source 'psrule' `
            -EntityId '/subscriptions/abc12345-6789-4abc-8def-1234567890ab/resourcegroups/rg/providers/microsoft.keyvault/vaults/kv1' `
            -EntityType 'AzureResource' `
            -Title 'Soft delete disabled' `
            -RuleId 'Azure.KeyVault.SoftDelete' `
            -Compliant $false `
            -ProvenanceRunId 'psrule-run-7'

        $finding.RuleId | Should -Be 'Azure.KeyVault.SoftDelete'
        $finding.SchemaVersion | Should -Be '2.2'
    }

    It 'accepts AdoProject as a valid EntityType (v2.1)' {
        $finding = New-FindingRow `
            -Id 'f-ado-project' `
            -Source 'ado-pipelines' `
            -EntityId 'ado://contoso/platform' `
            -EntityType 'AdoProject' `
            -Title 'Project lacks branch policy' `
            -Compliant $false `
            -ProvenanceRunId 'ado-run-1'

        $finding | Should -Not -BeNullOrEmpty
        $finding.EntityType | Should -Be 'AdoProject'
        $finding.Platform | Should -Be 'ADO'
    }

    It 'accepts KarpenterProvisioner as a valid EntityType (v2.1)' {
        $finding = New-FindingRow `
            -Id 'f-karpenter' `
            -Source 'aks-rightsizing' `
            -EntityId '/subscriptions/abc12345-6789-4abc-8def-1234567890ab/resourcegroups/rg-aks/providers/microsoft.containerservice/managedclusters/aks-prod/karpenter/np-default' `
            -EntityType 'KarpenterProvisioner' `
            -Title 'Karpenter NodePool over-provisioned' `
            -Compliant $false `
            -ProvenanceRunId 'karpenter-run-1'

        $finding | Should -Not -BeNullOrEmpty
        $finding.EntityType | Should -Be 'KarpenterProvisioner'
        $finding.Platform | Should -Be 'Azure'
    }

    It 'accepts BuildDefinition with AzureDevOps platform' {
        $finding = New-FindingRow `
            -Id 'f-build-def' `
            -Source 'ado-pipelines' `
            -EntityId 'contoso/payments/BuildDefinition/101' `
            -EntityType 'BuildDefinition' `
            -Title 'Build definition branch filter missing' `
            -Compliant $false `
            -ProvenanceRunId 'ado-run-2' `
            -Platform 'AzureDevOps'

        $finding | Should -Not -BeNullOrEmpty
        $finding.EntityType | Should -Be 'BuildDefinition'
        $finding.Platform | Should -Be 'AzureDevOps'
    }

    It 'accepts IaCFile as a valid EntityType (v2.2)' {
        $finding = New-FindingRow `
            -Id 'f-iac-file' `
            -Source 'terraform-iac' `
            -EntityId 'iac:terraform:infra/main.tf#azurerm_storage_account.main' `
            -EntityType 'IaCFile' `
            -Title 'Terraform misconfiguration' `
            -Compliant $false `
            -ProvenanceRunId 'terraform-run-1'

        $finding | Should -Not -BeNullOrEmpty
        $finding.EntityType | Should -Be 'IaCFile'
        $finding.Platform | Should -Be 'Azure'
    }
}

Describe 'Get-PlatformForEntityType (v2.1 additions)' {
    It 'maps AdoProject to ADO' {
        Get-PlatformForEntityType -EntityType 'AdoProject' | Should -Be 'ADO'
    }
    It 'maps KarpenterProvisioner to Azure' {
        Get-PlatformForEntityType -EntityType 'KarpenterProvisioner' | Should -Be 'Azure'
    }
    It 'maps BuildDefinition to AzureDevOps' {
        Get-PlatformForEntityType -EntityType 'BuildDefinition' | Should -Be 'AzureDevOps'
    }
    It 'maps ReleaseDefinition to AzureDevOps' {
        Get-PlatformForEntityType -EntityType 'ReleaseDefinition' | Should -Be 'AzureDevOps'
    }

    It 'maps IaCFile to Azure' {
        Get-PlatformForEntityType -EntityType 'IaCFile' | Should -Be 'Azure'
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

    It 'returns false with errors for non-canonical IDs' {
        $finding = [PSCustomObject]@{
            SchemaVersion = '2.1'
            Id            = 'f-003'
            Source        = 'azqr'
            Platform      = 'Azure'
            EntityType    = 'AzureResource'
            EntityId      = '/Subscriptions/ABC12345-6789-4ABC-8DEF-1234567890AB/ResourceGroups/rg/providers/Microsoft.Storage/storageAccounts/foo'
            SubscriptionId = 'abc12345-6789-4abc-8def-1234567890ab'
            ResourceGroup = 'rg'
            Category      = 'Security'
            Severity      = 'High'
            Title         = 'Invalid'
            Compliant     = $false
            RiskAccepted  = $false
            Description   = ''
            Recommendation = ''
            Links         = [PSCustomObject]@{}
            Evidence      = [PSCustomObject]@{}
            Tags          = @()
            Details       = [PSCustomObject]@{}
            TimestampUtc  = (Get-Date).ToUniversalTime().ToString('o')
            Provenance    = [PSCustomObject]@{
                Source = 'azqr'
                RunId  = 'azqr-run-2'
            }
        }

        $errors = @()
        (Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)) | Should -BeFalse
        ($errors -join '; ') | Should -Match 'EntityId'
    }

    It 'returns false with errors for missing required fields' {
        # Build a finding missing EntityId to test validation
        $finding = [PSCustomObject]@{
            Id               = 'f-003'
            Source           = 'azqr'
            EntityType       = 'AzureResource'
            Title            = 'Invalid'
            Compliant        = $false
            SchemaVersion    = '2.1'
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
            SchemaVersion    = '2.1'
            Platform         = 'Azure'
            Provenance       = [PSCustomObject]@{ RunId = 'azqr-run-3'; Source = 'azqr'; Timestamp = (Get-Date).ToUniversalTime().ToString('o') }
        }

        $errors = @()
        (Test-FindingRow -Finding $finding -ErrorDetails ([ref]$errors)) | Should -BeFalse
        ($errors -join '; ') | Should -Match "Compliant must be a boolean value, got 'null'"
    }
}


Describe 'New-FindingRow Schema 2.2 additive fields (#299)' {
    BeforeAll {
        $script:baseArgs = @{
            Id              = 'f-22'
            Source          = 'psrule'
            EntityId        = '/subscriptions/abc12345-6789-4abc-8def-1234567890ab/resourcegroups/rg/providers/microsoft.storage/storageaccounts/foo'
            EntityType      = 'AzureResource'
            Title           = 'Schema 2.2 round-trip'
            Compliant       = $false
            ProvenanceRunId = 'sv22-run-1'
        }
    }

    It 'defaults all 13 new fields to zero values when callers omit them (back-compat)' {
        $f = New-FindingRow @script:baseArgs
        $f | Should -Not -BeNullOrEmpty
        $f.SchemaVersion | Should -Be '2.2'
        $f.Pillar | Should -Be ''
        $f.Impact | Should -Be ''
        $f.Effort | Should -Be ''
        $f.DeepLinkUrl | Should -Be ''
        $f.ToolVersion | Should -Be ''
        ,$f.RemediationSnippets | Should -BeOfType [object[]]
        @($f.RemediationSnippets).Count | Should -Be 0
        @($f.EvidenceUris).Count | Should -Be 0
        @($f.BaselineTags).Count | Should -Be 0
        @($f.MitreTactics).Count | Should -Be 0
        @($f.MitreTechniques).Count | Should -Be 0
        @($f.EntityRefs).Count | Should -Be 0
        $f.ScoreDelta | Should -BeNullOrEmpty
    }

    It 'persists every new field on the row when supplied' {
        $snippet = @{ language = 'bicep'; code = 'resource sa Microsoft.Storage/storageAccounts@2023-01-01 = { ... }' }
        $framework = @{ kind = 'CIS'; controlId = '1.1.1'; version = '1.4.0' }
        $f = New-FindingRow @script:baseArgs `
            -Pillar 'Security' `
            -Impact 'High' `
            -Effort 'Low' `
            -DeepLinkUrl 'https://portal.azure.com/#resource/foo' `
            -RemediationSnippets @($snippet) `
            -EvidenceUris @('https://learn.microsoft.com/azure/storage/common/storage-redundancy') `
            -BaselineTags @('release:GA','baseline:cis-1.4') `
            -ScoreDelta -3.5 `
            -MitreTactics @('TA0001','TA0006') `
            -MitreTechniques @('T1078','T1552') `
            -EntityRefs @('/subscriptions/x/resourceGroups/y','spn:111') `
            -ToolVersion '1.42.0' `
            -Frameworks @($framework)

        $f.Pillar | Should -Be 'Security'
        $f.Impact | Should -Be 'High'
        $f.Effort | Should -Be 'Low'
        $f.DeepLinkUrl | Should -Be 'https://portal.azure.com/#resource/foo'
        @($f.RemediationSnippets).Count | Should -Be 1
        $f.RemediationSnippets[0].language | Should -Be 'bicep'
        $f.EvidenceUris | Should -Contain 'https://learn.microsoft.com/azure/storage/common/storage-redundancy'
        $f.BaselineTags | Should -Contain 'release:GA'
        $f.BaselineTags | Should -Contain 'baseline:cis-1.4'
        $f.ScoreDelta | Should -Be -3.5
        $f.MitreTactics | Should -Contain 'TA0001'
        $f.MitreTechniques | Should -Contain 'T1078'
        $f.EntityRefs | Should -Contain 'spn:111'
        $f.ToolVersion | Should -Be '1.42.0'
        @($f.Frameworks).Count | Should -Be 1
        $f.Frameworks[0].kind | Should -Be 'CIS'
        $f.Frameworks[0].controlId | Should -Be '1.1.1'
    }

    It 'round-trips Schema 2.2 fields through JSON serialization (EntityStore v3.1 envelope)' {
        $f = New-FindingRow @script:baseArgs `
            -Pillar 'Reliability' `
            -BaselineTags @('release:preview') `
            -EvidenceUris @('https://example.test/evidence') `
            -ScoreDelta 1.25 `
            -MitreTactics @('TA0040') `
            -ToolVersion '0.0.1'

        $json = $f | ConvertTo-Json -Depth 10
        $round = $json | ConvertFrom-Json
        $round.SchemaVersion | Should -Be '2.2'
        $round.Pillar | Should -Be 'Reliability'
        $round.BaselineTags | Should -Contain 'release:preview'
        $round.EvidenceUris | Should -Contain 'https://example.test/evidence'
        $round.ScoreDelta | Should -Be 1.25
        $round.MitreTactics | Should -Contain 'TA0040'
        $round.ToolVersion | Should -Be '0.0.1'
    }

    It 'accepts a nullable double for ScoreDelta (positive, negative, zero, null)' {
        foreach ($v in @(0.0, 1.5, -2.75)) {
            $f = New-FindingRow @script:baseArgs -ScoreDelta $v
            $f.ScoreDelta | Should -Be $v
        }
        $fNull = New-FindingRow @script:baseArgs
        $fNull.ScoreDelta | Should -BeNullOrEmpty
    }
}
