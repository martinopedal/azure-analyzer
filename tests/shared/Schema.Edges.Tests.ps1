#Requires -Version 7.4

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Sanitize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
}

Describe 'New-Edge factory' {
    It 'creates a deterministic EdgeId from source/relation/target' {
        $e1 = New-Edge -Source 'objectId:aaaa1111-bbbb-2222-cccc-333333333333' `
                      -Target 'tenant:dddd4444-5555-6666-7777-888888888888' `
                      -Relation 'GuestOf' -Confidence 'Confirmed' -Platform 'Entra' `
                      -DiscoveredBy 'identity-graph-expansion'
        $e2 = New-Edge -Source 'OBJECTID:AAAA1111-BBBB-2222-CCCC-333333333333' `
                      -Target 'TENANT:DDDD4444-5555-6666-7777-888888888888' `
                      -Relation 'GuestOf' -Confidence 'Confirmed' -Platform 'Entra' `
                      -DiscoveredBy 'identity-graph-expansion'
        $e1.EdgeId | Should -Be $e2.EdgeId
        $e1.EdgeId | Should -Match '^edge:objectid:'
    }

    It 'rejects unknown Relation values' {
        $e = New-Edge -Source 'a' -Target 'b' -Relation 'Bogus' 3>$null
        $e | Should -BeNullOrEmpty
    }

    It 'rejects unknown Confidence values' {
        $e = New-Edge -Source 'a' -Target 'b' -Relation 'GuestOf' -Confidence 'High' 3>$null
        $e | Should -BeNullOrEmpty
    }

    It 'requires non-empty Source and Target' {
        (New-Edge -Source '' -Target 't' -Relation 'GuestOf' 3>$null) | Should -BeNullOrEmpty
        (New-Edge -Source 's' -Target '' -Relation 'GuestOf' 3>$null) | Should -BeNullOrEmpty
    }

    It 'normalises Properties hashtables to PSCustomObject' {
        $e = New-Edge -Source 's' -Target 't' -Relation 'HasRoleOn' `
                     -Properties @{ RoleName = 'Owner' } -Confidence 'Confirmed'
        $e.Properties.RoleName | Should -Be 'Owner'
    }

    It 'stamps SchemaVersion 3.1' {
        $e = New-Edge -Source 's' -Target 't' -Relation 'MemberOf' -Confidence 'Confirmed'
        $e.SchemaVersion | Should -Be '3.1'
    }
}

Describe 'Get-EdgeRelations enum' {
    It 'lists the documented relations' {
        $rels = Get-EdgeRelations
        foreach ($expected in @('GuestOf','MemberOf','HasRoleOn','OwnsAppRegistration','ConsentedTo','TriggeredBy','DependsOn','PolicyAssignedTo','InheritsFrom')) {
            $rels | Should -Contain $expected
        }
    }
}

Describe 'Test-Edge validator' {
    It 'accepts a well-formed edge' {
        $e = New-Edge -Source 's' -Target 't' -Relation 'MemberOf' -Confidence 'Likely'
        $errs = $null
        (Test-Edge -Edge $e -ErrorDetails ([ref]$errs)) | Should -BeTrue
    }

    It 'rejects an edge missing required fields' {
        $bad = [PSCustomObject]@{ EdgeId = ''; Source = ''; Target = 't'; Relation = 'MemberOf' }
        $errs = $null
        (Test-Edge -Edge $bad -ErrorDetails ([ref]$errs)) | Should -BeFalse
        ($errs -join ' ') | Should -Match 'Source'
    }
}
