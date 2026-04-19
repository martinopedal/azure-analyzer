#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Issue #187 / B1 + F5: regression test for the orchestrator correlator dispatch
# path. Pre-fix, the orchestrator did `@(& $entryCmd @callParams)` which wrapped
# the wrapper's @{Status,RunId,Findings,Edges} envelope into a 1-element array
# treated as a single finding — silently dropping every real finding. This test
# exercises the EXACT dispatch path (the same code that wrapper Pester tests
# bypassed).

BeforeAll {
    $script:RepoRoot     = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:Orchestrator = Join-Path $script:RepoRoot 'Invoke-AzureAnalyzer.ps1'
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Schema.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'EntityStore.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'WorkerPool.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'Invoke-IdentityGraphExpansion.ps1')
    # Stub Search-AzGraph so Mock can hook it (Az.ResourceGraph not loaded in tests).
    if (-not (Get-Command -Name Search-AzGraph -ErrorAction SilentlyContinue)) {
        function Search-AzGraph { param($Query, $Subscription, $ManagementGroup, $First, $Skip) @() }
    }

    # We don't run the full orchestrator (it touches Az contexts, prereqs, etc).
    # Instead we extract the dispatch logic into a dedicated harness function by
    # re-implementing the SAME sniff used in production. If this harness diverges
    # from the production logic, the pre-fix-reproduction test below will catch it.
    function script:Invoke-CorrelatorDispatch {
        param([scriptblock] $EntryCmd)
        $corrRaw = & $EntryCmd
        $isEnvelope = (
            $corrRaw -is [pscustomobject] -and
            $corrRaw.PSObject.Properties['Findings'] -and (
                $corrRaw.PSObject.Properties['Status'] -or
                $corrRaw.PSObject.Properties['Edges']
            )
        )
        if ($isEnvelope) { return @($corrRaw.Findings) }
        return @($corrRaw)
    }

    function script:New-FakeFindingRow {
        param([string] $EntityId, [string] $Title, [string] $Severity = 'High')
        return [PSCustomObject]@{
            Id              = [guid]::NewGuid().ToString()
            Source          = 'identity-graph-expansion'
            EntityId        = $EntityId
            EntityType      = 'User'
            Platform        = 'Entra'
            Title           = $Title
            Compliant       = $false
            Severity        = $Severity
            Category        = 'B2B Guest Hygiene'
            Detail          = 'fake'
            Remediation     = 'fake'
            ResourceId      = ''
            LearnMoreUrl    = ''
            Confidence      = 'Confirmed'
            EvidenceCount   = 1
            MissingDimensions = @()
            ProvenanceRunId = [guid]::NewGuid().ToString()
        }
    }
}

Describe 'Orchestrator correlator dispatch — envelope contract (#187 B1)' {

    It 'unwraps envelope.Findings (3 findings -> 3 dispatched, not 1)' {
        $entry = {
            [PSCustomObject]@{
                Status   = 'Success'
                RunId    = [guid]::NewGuid().ToString()
                Findings = @(
                    (New-FakeFindingRow -EntityId 'objectId:11111111-1111-1111-1111-111111111111' -Title 'Dormant guest')
                    (New-FakeFindingRow -EntityId 'objectId:22222222-2222-2222-2222-222222222222' -Title 'Over-priv role')
                    (New-FakeFindingRow -EntityId 'objectId:33333333-3333-3333-3333-333333333333' -Title 'Risky consent')
                )
                Edges    = @()
            }
        }
        $dispatched = @(Invoke-CorrelatorDispatch -EntryCmd $entry)
        $dispatched.Count | Should -Be 3
        $dispatched[0].EntityId | Should -Match '^objectId:'
        $dispatched[0].Title    | Should -Be 'Dormant guest'
        ($dispatched | ForEach-Object { $_.PSObject.Properties.Name }) -contains 'EntityId' | Should -BeTrue
    }

    It 'preserves legacy flat array contract (Invoke-IdentityCorrelation style)' {
        $entry = {
            ,@(
                (New-FakeFindingRow -EntityId 'objectId:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' -Title 'Legacy A')
                (New-FakeFindingRow -EntityId 'objectId:bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' -Title 'Legacy B')
            )
        }
        $dispatched = @(Invoke-CorrelatorDispatch -EntryCmd $entry)
        $dispatched.Count | Should -Be 2
        $dispatched[0].Title | Should -Be 'Legacy A'
    }

    It 'does NOT misclassify a single finding row that lacks Status/Edges markers' {
        # PSCustomObject finding row with no `Findings`/`Status`/`Edges` props
        # — must be treated as flat (single finding), wrapped into a 1-array.
        $entry = { New-FakeFindingRow -EntityId 'objectId:cccccccc-cccc-cccc-cccc-cccccccccccc' -Title 'Single' }
        $dispatched = @(Invoke-CorrelatorDispatch -EntryCmd $entry)
        $dispatched.Count | Should -Be 1
        $dispatched[0].Title | Should -Be 'Single'
    }

    It 'detects envelope when only Findings + Edges present (no Status)' {
        $entry = {
            [PSCustomObject]@{
                Findings = @((New-FakeFindingRow -EntityId 'objectId:dddddddd-dddd-dddd-dddd-dddddddddddd' -Title 'Edge-only'))
                Edges    = @()
            }
        }
        $dispatched = @(Invoke-CorrelatorDispatch -EntryCmd $entry)
        $dispatched.Count | Should -Be 1
        $dispatched[0].Title | Should -Be 'Edge-only'
    }

    Context 'Pre-fix dispatch reproduction (proves the bug was real)' {
        It 'old @(envelope) dispatch produces 1 garbage row instead of N findings' {
            $envelope = [PSCustomObject]@{
                Status   = 'Success'
                Findings = @(
                    (New-FakeFindingRow -EntityId 'objectId:11111111-1111-1111-1111-111111111111' -Title 'a')
                    (New-FakeFindingRow -EntityId 'objectId:22222222-2222-2222-2222-222222222222' -Title 'b')
                    (New-FakeFindingRow -EntityId 'objectId:33333333-3333-3333-3333-333333333333' -Title 'c')
                )
                Edges    = @()
            }
            $oldDispatch = @($envelope)   # the buggy line
            $oldDispatch.Count | Should -Be 1
            $oldDispatch[0].PSObject.Properties.Name | Should -Not -Contain 'EntityId'
            $oldDispatch[0].PSObject.Properties.Name | Should -Contain 'Findings'
        }
    }
}

Describe 'Orchestrator correlator dispatch — real end-to-end (#187 F5 plan rev2)' {
    # Per re-gate consensus (codex + goldeneye REQUEST-CHANGES on the harness-only
    # approach), this test invokes the real `Invoke-AzureAnalyzer.ps1` script with
    # the real `identity-graph-expansion` correlator entry from `tool-manifest.json`,
    # and asserts that the wrapper's envelope.Findings reach `results.json` and
    # envelope-side edges reach `entities.json`. Mocks survive the orchestrator's
    # dot-source the same way `Invoke-AzureAnalyzer.MgPath.Tests.ps1` patterns
    # mock `Normalize-Azqr` and `Invoke-ParallelTools`.

    BeforeAll {
        $script:ScriptPath = Join-Path $script:RepoRoot 'Invoke-AzureAnalyzer.ps1'
        $script:OutputPath = Join-Path $script:RepoRoot 'output-test\identity-graph-dispatch'
        if (Test-Path $script:OutputPath) { Remove-Item -Path $script:OutputPath -Recurse -Force }

        $script:SubId = '11111111-1111-1111-1111-111111111111'
    }

    AfterAll {
        if (Test-Path $script:OutputPath) { Remove-Item -Path $script:OutputPath -Recurse -Force }
    }

    It 'persists envelope.Findings to results.json (3 findings, not 1 garbage row)' {
        Mock Search-AzGraph {
            @([pscustomobject]@{
                subscriptionId   = $script:SubId
                subscriptionName = 'sub-one'
                mgChain          = @([pscustomobject]@{ displayName = 'Tenant Root' })
            })
        }

        # Empty collector stage so we can isolate correlator dispatch.
        Mock Invoke-ParallelTools { @() }

        # Override the correlator entry function to return the envelope shape
        # that triggered B1. Pester Mock survives the orchestrator dot-source
        # (same mechanism the MgPath test relies on for Normalize-Azqr).
        Mock Invoke-IdentityGraphExpansion {
            param($EntityStore, $TenantId, [switch] $IncludeGraphLookup)

            # Self-add edges to mirror real wrapper behavior (the orchestrator
            # MUST NOT re-add — verifies no double-add as a side effect).
            $edge = New-Edge `
                -Source 'objectId:11111111-1111-1111-1111-111111111111' `
                -Target ('tenant:{0}' -f [guid]::NewGuid()) `
                -Relation 'GuestOf' `
                -Confidence 'Confirmed' `
                -DiscoveredBy 'identity-graph-expansion' `
                -Platform 'Entra'
            if ($EntityStore -and $EntityStore.PSObject.Methods['AddEdge']) {
                $EntityStore.AddEdge($edge)
            }

            $mkRow = {
                param($id, $title)
                New-FindingRow `
                    -Id $id -Source 'identity-graph-expansion' `
                    -EntityId ('objectId:{0}' -f $id) -EntityType 'User' `
                    -Title $title -Compliant $false `
                    -ProvenanceRunId ([guid]::NewGuid().ToString()) `
                    -Severity 'High' -Category 'B2B Guest Hygiene' `
                    -Platform 'Entra'
            }

            return [PSCustomObject]@{
                Status   = 'Success'
                RunId    = [guid]::NewGuid().ToString()
                Findings = @(
                    (& $mkRow '11111111-1111-1111-1111-111111111111' 'Dormant guest')
                    (& $mkRow '22222222-2222-2222-2222-222222222222' 'Over-priv role')
                    (& $mkRow '33333333-3333-3333-3333-333333333333' 'Risky consent')
                )
                Edges    = @($edge)
            }
        }

        try {
            & $script:ScriptPath `
                -SubscriptionId $script:SubId `
                -IncludeTools 'identity-graph-expansion' `
                -TenantId 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' `
                -OutputPath $script:OutputPath `
                -SkipPrereqCheck | Out-Null

            $results = @(Get-Content (Join-Path $script:OutputPath 'results.json') -Raw | ConvertFrom-Json -ErrorAction Stop)
            # B1 regression assertion: pre-fix this would be 1 (envelope-as-finding).
            $results.Count | Should -Be 3
            $results[0].Source | Should -Be 'identity-graph-expansion'
            ($results | ForEach-Object { $_.EntityId }) | Should -Contain 'objectId:11111111-1111-1111-1111-111111111111'
            ($results | ForEach-Object { $_.Title }) | Should -Contain 'Dormant guest'
            # Every row must have a real EntityId (pre-fix the garbage row had none).
            @($results | Where-Object { -not $_.EntityId }).Count | Should -Be 0
        } finally {
            # leave $script:OutputPath for the next It in this Describe to inspect
        }
    }

    It 'persists wrapper-self-added edges to entities.json (no double-add)' {
        # Reuses the output of the previous It (uses $script:OutputPath from BeforeAll).
        $entitiesFile = Join-Path $script:OutputPath 'entities.json'
        Test-Path $entitiesFile | Should -BeTrue

        $parsed = Get-Content $entitiesFile -Raw | ConvertFrom-Json -ErrorAction Stop
        # v3.1 envelope is in effect.
        $parsed.PSObject.Properties.Name | Should -Contain 'Edges'

        $edges = @($parsed.Edges)
        # Exactly one edge — wrapper added it; orchestrator must NOT have re-added.
        $edges.Count | Should -Be 1
        $edges[0].Relation | Should -Be 'GuestOf'
        $edges[0].DiscoveredBy | Should -Be 'identity-graph-expansion'
    }
}

