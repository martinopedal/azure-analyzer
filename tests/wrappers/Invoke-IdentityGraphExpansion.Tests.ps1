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

    # Cmdlet stubs: allow Pester to mock Graph/Az cmdlets without real module installs.
    # Get-Command finds global-scope functions, making the module-guard checks pass.
    foreach ($stub in @(
        'Get-MgUser', 'Get-MgServicePrincipal',
        'Get-MgUserMemberOf', 'Get-MgServicePrincipalMemberOf',
        'Get-AzRoleAssignment',
        'Get-MgUserOwnedApplication', 'Get-MgServicePrincipalOwnedObject',
        'Get-MgOAuth2PermissionGrant'
    )) {
        if (-not (Get-Command $stub -ErrorAction SilentlyContinue)) {
            $null = New-Item -Path "Function:global:$stub" -Value { }
        }
    }

    function global:New-IgxTestStore {
        param([string] $Suffix = '')
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("igx-$Suffix-" + [guid]::NewGuid().ToString())
        return [EntityStore]::new(50000, $tmp)
    }

    function global:Add-IgxUserEntity {
        param([EntityStore] $Store, [string] $Oid = '11111111-aaaa-bbbb-cccc-111111111111')
        $Store.MergeEntityMetadata([pscustomobject]@{
            EntityId      = "objectId:$Oid"
            EntityType    = 'User'
            Platform      = 'Entra'
            Observations  = $null
        })
    }
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

    It 'result envelope includes an ExpansionSummary property' {
        $script:result.PSObject.Properties.Name | Should -Contain 'ExpansionSummary'
        # ExpansionSummary is @() when using PreFetchedData (no live collectors ran).
        ($script:result.ExpansionSummary -is [System.Array]) | Should -BeTrue
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

Describe 'Get-IdentityGraphExpansionData live collectors (mock-based)' {
    BeforeAll {
        # Passthrough mock: Invoke-WithRetry invocations are assertable while
        # ScriptBlocks still execute (so inner mocks are reached).
        Mock Invoke-WithRetry   { param($ScriptBlock) & $ScriptBlock }
        Mock Remove-Credentials { param($Text) $Text }

        Mock Get-MgUser                      { @() }
        Mock Get-MgServicePrincipal          { $null }
        Mock Get-MgUserMemberOf              { @([PSCustomObject]@{ Id = 'aabbccdd-1111-2222-3333-aabbccdd1111'; DisplayName = 'Finance' }) }
        Mock Get-MgServicePrincipalMemberOf  { @() }
        Mock Get-AzRoleAssignment            { @([PSCustomObject]@{ Scope = '/subscriptions/12345678-1234-1234-1234-123456789012'; RoleDefinitionName = 'Reader' }) }
        Mock Get-MgUserOwnedApplication      { @([PSCustomObject]@{ Id = 'bbbbbbbb-cccc-dddd-eeee-bbbbbbbbbbbb'; DisplayName = 'MyApp' }) }
        Mock Get-MgServicePrincipalOwnedObject { @() }
        Mock Get-MgOAuth2PermissionGrant     { @([PSCustomObject]@{ ClientId = 'c1c1c1c1-1111-2222-3333-c1c1c1c1c1c1'; ResourceId = 'r1r1r1r1-1111-2222-3333-r1r1r1r1r1r1'; ConsentType = 'AllPrincipals'; Scope = 'openid' }) }
    }

    Context 'GroupMemberships collector' {
        It 'wraps Get-MgUserMemberOf in Invoke-WithRetry' {
            $store = New-IgxTestStore 'grp'
            Add-IgxUserEntity -Store $store
            Get-IdentityGraphExpansionData -IncludeGraphLookup -EntityStore $store -MaxPrincipals 1000
            Should -Invoke Invoke-WithRetry -Times 1
        }

        It 'returns group membership rows for known User entities' {
            $store = New-IgxTestStore 'grp2'
            Add-IgxUserEntity -Store $store
            $data = Get-IdentityGraphExpansionData -IncludeGraphLookup -EntityStore $store -MaxPrincipals 1000
            @($data.GroupMemberships).Count | Should -BeGreaterOrEqual 1
        }

        It 'calls Remove-Credentials when Get-MgUserMemberOf throws' {
            $store = New-IgxTestStore 'grp-err'
            Add-IgxUserEntity -Store $store
            Mock Get-MgUserMemberOf { throw 'token=leaked-secret-xyz error' }
            Get-IdentityGraphExpansionData -IncludeGraphLookup -EntityStore $store -MaxPrincipals 1000 3>$null
            Should -Invoke Remove-Credentials -Times 1
        }
    }

    Context 'RbacAssignments collector' {
        It 'wraps Get-AzRoleAssignment in Invoke-WithRetry' {
            $store = New-IgxTestStore 'rbac'
            Add-IgxUserEntity -Store $store
            Get-IdentityGraphExpansionData -IncludeGraphLookup -EntityStore $store -MaxPrincipals 1000
            Should -Invoke Invoke-WithRetry -Times 1
        }

        It 'returns RBAC assignment rows for known User entities' {
            $store = New-IgxTestStore 'rbac2'
            Add-IgxUserEntity -Store $store
            $data = Get-IdentityGraphExpansionData -IncludeGraphLookup -EntityStore $store -MaxPrincipals 1000
            @($data.RbacAssignments).Count | Should -BeGreaterOrEqual 1
        }

        It 'calls Remove-Credentials when Get-AzRoleAssignment throws' {
            $store = New-IgxTestStore 'rbac-err'
            Add-IgxUserEntity -Store $store
            Mock Get-AzRoleAssignment { throw 'token=leaked-secret-xyz error' }
            Get-IdentityGraphExpansionData -IncludeGraphLookup -EntityStore $store -MaxPrincipals 1000 3>$null
            Should -Invoke Remove-Credentials -Times 1
        }
    }

    Context 'AppOwnerships collector' {
        It 'wraps Get-MgUserOwnedApplication in Invoke-WithRetry' {
            $store = New-IgxTestStore 'own'
            Add-IgxUserEntity -Store $store
            Get-IdentityGraphExpansionData -IncludeGraphLookup -EntityStore $store -MaxPrincipals 1000
            Should -Invoke Invoke-WithRetry -Times 1
        }

        It 'returns ownership rows for known User entities' {
            $store = New-IgxTestStore 'own2'
            Add-IgxUserEntity -Store $store
            $data = Get-IdentityGraphExpansionData -IncludeGraphLookup -EntityStore $store -MaxPrincipals 1000
            @($data.AppOwnerships).Count | Should -BeGreaterOrEqual 1
        }

        It 'calls Remove-Credentials when Get-MgUserOwnedApplication throws' {
            $store = New-IgxTestStore 'own-err'
            Add-IgxUserEntity -Store $store
            Mock Get-MgUserOwnedApplication { throw 'token=leaked-secret-xyz error' }
            Get-IdentityGraphExpansionData -IncludeGraphLookup -EntityStore $store -MaxPrincipals 1000 3>$null
            Should -Invoke Remove-Credentials -Times 1
        }
    }

    Context 'ConsentGrants collector' {
        It 'calls Get-MgOAuth2PermissionGrant exactly once (bulk, not per-principal)' {
            $store = New-IgxTestStore 'consent'
            Get-IdentityGraphExpansionData -IncludeGraphLookup -EntityStore $store -MaxPrincipals 1000
            Should -Invoke Get-MgOAuth2PermissionGrant -Times 1 -Exactly
        }

        It 'returns consent grant rows' {
            $store = New-IgxTestStore 'consent2'
            $data = Get-IdentityGraphExpansionData -IncludeGraphLookup -EntityStore $store -MaxPrincipals 1000
            @($data.ConsentGrants).Count | Should -BeGreaterOrEqual 1
        }

        It 'calls Remove-Credentials when Get-MgOAuth2PermissionGrant throws' {
            $store = New-IgxTestStore 'consent-err'
            Mock Get-MgOAuth2PermissionGrant { throw 'token=leaked-secret-xyz error' }
            Get-IdentityGraphExpansionData -IncludeGraphLookup -EntityStore $store -MaxPrincipals 1000 3>$null
            Should -Invoke Remove-Credentials -Times 1
        }
    }

    Context 'ExpansionSummary' {
        It 'includes a summary entry for each collector' {
            $store = New-IgxTestStore 'summary'
            Add-IgxUserEntity -Store $store
            $data = Get-IdentityGraphExpansionData -IncludeGraphLookup -EntityStore $store -MaxPrincipals 1000
            $collectors = @($data.ExpansionSummary | ForEach-Object { $_.Collector })
            $collectors | Should -Contain 'GroupMemberships'
            $collectors | Should -Contain 'RbacAssignments'
            $collectors | Should -Contain 'AppOwnerships'
            $collectors | Should -Contain 'ConsentGrants'
        }
    }
}

Describe 'Invoke-IdentityGraphExpansion principal cap' {
    BeforeAll {
        Mock Invoke-WithRetry         { param($ScriptBlock) & $ScriptBlock }
        Mock Get-MgUser               { @() }
        Mock Get-MgUserMemberOf       { @() }
        Mock Get-AzRoleAssignment     { @() }
        Mock Get-MgUserOwnedApplication   { @() }
        Mock Get-MgOAuth2PermissionGrant  { @() }
    }

    It 'emits an Info finding when principal count exceeds MaxPrincipals' {
        $store = New-IgxTestStore 'cap'
        1..5 | ForEach-Object {
            $oid = [guid]::NewGuid().ToString()
            $store.MergeEntityMetadata([pscustomobject]@{ EntityId = "objectId:$oid"; EntityType = 'User'; Platform = 'Entra'; Observations = $null })
        }
        $result = Invoke-IdentityGraphExpansion -EntityStore $store -TenantId 'tid' -IncludeGraphLookup -MaxPrincipals 3
        $capFindings = @($result.Findings | Where-Object { $_.Category -eq 'Expansion Cap' })
        $capFindings.Count | Should -Be 1
        $capFindings[0].Severity | Should -Be 'Info'
        $capFindings[0].Compliant | Should -BeTrue
    }

    It 'does not emit a cap finding when principal count is within limit' {
        $store = New-IgxTestStore 'nocap'
        $oid = [guid]::NewGuid().ToString()
        $store.MergeEntityMetadata([pscustomobject]@{ EntityId = "objectId:$oid"; EntityType = 'User'; Platform = 'Entra'; Observations = $null })
        $result = Invoke-IdentityGraphExpansion -EntityStore $store -TenantId 'tid' -IncludeGraphLookup -MaxPrincipals 100
        $capFindings = @($result.Findings | Where-Object { $_.Category -eq 'Expansion Cap' })
        $capFindings.Count | Should -Be 0
    }
}

Describe 'Invoke-IdentityGraphExpansion throttle skip' {
    BeforeAll {
        Mock Invoke-WithRetry            { param($ScriptBlock) & $ScriptBlock }
        Mock Get-MgUser                  { @() }
        Mock Get-AzRoleAssignment        { @() }
        Mock Get-MgUserOwnedApplication  { @() }
        Mock Get-MgOAuth2PermissionGrant { @() }
        # Always throws a 429-style message to trigger the 3-consecutive-429 short-circuit.
        Mock Get-MgUserMemberOf { throw '429 Too Many Requests - throttled by Graph' }
    }

    It 'emits a Throttle Skip Info finding after 3 consecutive 429 responses' {
        $store = New-IgxTestStore 'throttle'
        1..3 | ForEach-Object {
            $oid = [guid]::NewGuid().ToString()
            $store.MergeEntityMetadata([pscustomobject]@{ EntityId = "objectId:$oid"; EntityType = 'User'; Platform = 'Entra'; Observations = $null })
        }
        $result = Invoke-IdentityGraphExpansion -EntityStore $store -TenantId 'tid' -IncludeGraphLookup 3>$null
        $throttleFindings = @($result.Findings | Where-Object { $_.Category -eq 'Throttle Skip' })
        $throttleFindings.Count | Should -BeGreaterOrEqual 1
        $throttleFindings[0].Severity | Should -Be 'Info'
        $throttleFindings[0].Compliant | Should -BeTrue
    }
}

Describe 'Invoke-IdentityGraphExpansion large fixture correctness' {
    It 'processes 1000 group membership edges from a synthetic fixture with correct counts' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("igx-perf-" + [guid]::NewGuid().ToString())
        $store = [EntityStore]::new(50000, $tmp)

        # Use real GUIDs so ConvertTo-CanonicalEntityId succeeds for every entry.
        $memberships = 1..1000 | ForEach-Object {
            [PSCustomObject]@{
                PrincipalId   = [guid]::NewGuid().ToString()
                PrincipalType = 'User'
                GroupId       = [guid]::NewGuid().ToString()
                GroupName     = "Group $_"
            }
        }
        $syntheticFixture = [PSCustomObject]@{
            Guests           = @()
            GroupMemberships = $memberships
            RbacAssignments  = @()
            AppOwnerships    = @()
            ConsentGrants    = @()
        }

        $elapsed = Measure-Command {
            $result = Invoke-IdentityGraphExpansion -EntityStore $store -TenantId 'perf-test' -PreFetchedData $syntheticFixture
        }

        # Correctness: all 1000 MemberOf edges must be emitted.
        $memberEdges = @($result.Edges | Where-Object { $_.Relation -eq 'MemberOf' })
        $memberEdges.Count | Should -Be 1000

        # Fixture-mode has no live Graph calls; processing should be fast.
        $elapsed.TotalSeconds | Should -BeLessThan 30
    }
}
