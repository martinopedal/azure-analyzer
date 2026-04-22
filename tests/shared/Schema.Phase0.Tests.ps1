#Requires -Version 7.4

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    . (Join-Path $repoRoot 'modules\shared\Sanitize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
}

Describe 'Phase 0 (#435) EdgeRelations additions' {
    BeforeAll {
        $script:Phase0Relations = @(
            'TriggeredBy','AuthenticatesAs','DeploysTo','UsesSecret','HasFederatedCredential','Declares',
            'DependsOn','RegionPinned','ZonePinned','BackedUpBy','FailsOverTo','ReplicatedTo',
            'PolicyAssignedTo','PolicyEnforces','ExemptedFrom','InheritsFrom'
        )
    }

    It 'exposes all 16 new relations through Get-EdgeRelations' {
        $rels = @((Get-EdgeRelations) | ForEach-Object { $_ })
        foreach ($expected in $script:Phase0Relations) {
            $rels | Should -Contain $expected
        }
    }

    It 'preserves the legacy 5 relations from earlier schema versions' {
        $rels = @((Get-EdgeRelations) | ForEach-Object { $_ })
        foreach ($legacy in @('GuestOf','MemberOf','HasRoleOn','OwnsAppRegistration','ConsentedTo')) {
            $rels | Should -Contain $legacy
        }
    }

    It 'accepts each new relation in New-Edge without warning' {
        foreach ($rel in $script:Phase0Relations) {
            $edge = New-Edge -Source 'src:1' -Target 'tgt:2' -Relation $rel -Confidence 'Likely' -Platform 'Azure'
            $edge | Should -Not -BeNullOrEmpty
            $edge.Relation | Should -Be $rel
            $edge.SchemaVersion | Should -Be '3.1'
        }
    }

    It 'still rejects unknown relations' {
        $bogus = New-Edge -Source 's' -Target 't' -Relation 'NotARealRelation' 3>$null
        $bogus | Should -BeNullOrEmpty
    }
}

Describe 'Phase 0 (#435) FindingRow AdditionalFields hook' {
    BeforeEach {
        Reset-SchemaValidationFailures
    }

    It 'merges unknown additive keys into the row' {
        $row = New-FindingRow -Id 'f1' -Source 'phase0' -EntityId 'tenant:00000000-0000-0000-0000-000000000001' `
            -EntityType 'Tenant' -Title 'phase0 hook test' -Compliant $false -ProvenanceRunId 'r1' `
            -Severity 'Low' `
            -AdditionalFields @{ DocsUrl = 'https://aka.ms/phase0'; SuggestedPolicies = @('alz/policy-1') }
        $row | Should -Not -BeNullOrEmpty
        $row.PSObject.Properties.Name | Should -Contain 'DocsUrl'
        $row.DocsUrl | Should -Be 'https://aka.ms/phase0'
        $row.PSObject.Properties.Name | Should -Contain 'SuggestedPolicies'
        @($row.SuggestedPolicies)[0] | Should -Be 'alz/policy-1'
    }

    It 'silently drops keys that collide with first-class fields' {
        $row = New-FindingRow -Id 'f2' -Source 'phase0' -EntityId 'tenant:00000000-0000-0000-0000-000000000002' `
            -EntityType 'Tenant' -Title 'collision test' -Compliant $true -ProvenanceRunId 'r2' `
            -Severity 'Info' `
            -AdditionalFields @{ Severity = 'Critical'; Title = 'overwrite attempt' }
        $row | Should -Not -BeNullOrEmpty
        $row.Severity | Should -Be 'Info'
        $row.Title | Should -Be 'collision test'
    }

    It 'is a no-op when AdditionalFields is empty' {
        $row = New-FindingRow -Id 'f3' -Source 'phase0' -EntityId 'tenant:00000000-0000-0000-0000-000000000003' `
            -EntityType 'Tenant' -Title 'no extras' -Compliant $true -ProvenanceRunId 'r3' -Severity 'Info'
        $row | Should -Not -BeNullOrEmpty
        $row.Title | Should -Be 'no extras'
    }
}
