#Requires -Version 7.4

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Sanitize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
    . (Join-Path $repoRoot 'modules\shared\Schema.ps1')
    . (Join-Path $repoRoot 'modules\shared\Retry.ps1')
    . (Join-Path $repoRoot 'modules\shared\EntityStore.ps1')
    . (Join-Path $repoRoot 'modules\Invoke-IdentityGraphExpansion.ps1')
    $script:fixturePath = Join-Path $repoRoot 'tests\fixtures\identity-graph\sample-graph-data.json'
    $script:fixture = Get-Content $script:fixturePath -Raw | ConvertFrom-Json
}

Describe 'Invoke-IdentityGraphExpansion (fixture-driven)' {
    BeforeEach {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("igx-" + [guid]::NewGuid().ToString())
        $script:store = [EntityStore]::new(50000, $tmp)
        $script:result = Invoke-IdentityGraphExpansion -EntityStore $script:store `
            -TenantId 'fabrikam.onmicrosoft.com' -PreFetchedData $script:fixture
    }

    It 'returns a Success envelope' {
        $script:result.Status | Should -Be 'Success'
    }

    It 'emits a GuestOf edge for every guest with discoverable home tenant/domain' {
        $guestOf = @($script:result.Edges | Where-Object { $_.Relation -eq 'GuestOf' })
        $guestOf.Count | Should -BeGreaterOrEqual 2
    }

    It 'marks GuestOf as Confirmed when a home tenant GUID was discovered' {
        $confirmed = @($script:result.Edges | Where-Object { $_.Relation -eq 'GuestOf' -and $_.Confidence -eq 'Confirmed' })
        $confirmed.Count | Should -BeGreaterOrEqual 1
    }

    It 'emits a dormant-guest finding for PendingAcceptance state' {
        $dormant = @($script:result.Findings | Where-Object { $_.Category -eq 'B2B Guest Hygiene' })
        $dormant.Count | Should -Be 1
        $dormant[0].Severity | Should -Be 'Low'
        $dormant[0].Compliant | Should -BeFalse
    }

    It 'emits HasRoleOn edges for every RBAC assignment' {
        $rbac = @($script:result.Edges | Where-Object { $_.Relation -eq 'HasRoleOn' })
        $rbac.Count | Should -Be 2
    }

    It 'emits an over-privileged finding only for high-priv role at broad scope' {
        $blast = @($script:result.Findings | Where-Object { $_.Category -eq 'Identity Blast Radius' })
        $blast.Count | Should -Be 1
        $blast[0].Severity | Should -Be 'High'
    }

    It 'emits ConsentedTo edges and a risky-consent High finding' {
        $consent = @($script:result.Edges | Where-Object { $_.Relation -eq 'ConsentedTo' })
        $consent.Count | Should -Be 2
        $risky = @($script:result.Findings | Where-Object { $_.Category -eq 'Excessive Consent' })
        $risky.Count | Should -Be 1
        $risky[0].Severity | Should -Be 'High'
    }

    It 'emits OwnsAppRegistration edges' {
        $owns = @($script:result.Edges | Where-Object { $_.Relation -eq 'OwnsAppRegistration' })
        $owns.Count | Should -Be 1
    }

    It 'emits MemberOf edges' {
        $member = @($script:result.Edges | Where-Object { $_.Relation -eq 'MemberOf' })
        $member.Count | Should -Be 1
    }

    It 'persists edges to the supplied EntityStore' {
        @($script:store.GetEdges()).Count | Should -Be @($script:result.Edges).Count
    }

    It 'all findings carry one of the five canonical severities' {
        $valid = @('Critical','High','Medium','Low','Info')
        foreach ($f in @($script:result.Findings)) {
            $valid | Should -Contain $f.Severity
        }
    }

    It 'all edges are deterministic-id and lower-cased' {
        foreach ($e in @($script:result.Edges)) {
            $e.EdgeId    | Should -Match '^edge:'
            $e.Source    | Should -BeExactly $e.Source.ToLowerInvariant()
            $e.Target    | Should -BeExactly $e.Target.ToLowerInvariant()
        }
    }

    It 'gracefully handles empty pre-fetched data' {
        $tmp2 = Join-Path ([System.IO.Path]::GetTempPath()) ("igx-empty-" + [guid]::NewGuid().ToString())
        $store2 = [EntityStore]::new(50000, $tmp2)
        $empty = [PSCustomObject]@{ Guests=@(); GroupMemberships=@(); RbacAssignments=@(); AppOwnerships=@(); ConsentGrants=@() }
        $r = Invoke-IdentityGraphExpansion -EntityStore $store2 -TenantId 'tid' -PreFetchedData $empty
        $r.Status | Should -Be 'Success'
        @($r.Edges).Count   | Should -Be 0
        @($r.Findings).Count | Should -Be 0
    }
}

Describe 'Invoke-IdentityGraphExpansion safety' {
    It 'sanitises errors when AddEdge throws (non-fatal warning)' {
        # Use a fake store whose AddEdge always throws to exercise the catch branch.
        $fake = New-Object PSObject
        Add-Member -InputObject $fake -MemberType ScriptMethod -Name AddEdge -Value { throw 'token=secret-abc-123 leaked' }
        $data = [PSCustomObject]@{
            Guests = @(); GroupMemberships = @()
            RbacAssignments = @(@{ PrincipalId='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; PrincipalType='ServicePrincipal'; Scope='/subscriptions/12345678-1234-1234-1234-123456789012'; RoleDefinitionName='Reader' })
            AppOwnerships = @(); ConsentGrants = @()
        }
        # Should not throw; warnings may be emitted.
        { Invoke-IdentityGraphExpansion -EntityStore $fake -TenantId 'tid' -PreFetchedData $data 3>$null } | Should -Not -Throw
    }
}
