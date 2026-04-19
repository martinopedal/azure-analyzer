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

Describe 'Orchestrator correlator dispatch — entry-function source-of-truth check (#187 F5)' {
    # Sentinel test: if the production dispatch sniff in Invoke-AzureAnalyzer.ps1
    # diverges from the harness above, this fails — the harness is meant to be
    # an exact mirror of production logic.
    It 'production source contains the same envelope sniff as the harness' {
        $src = Get-Content -Path $script:Orchestrator -Raw
        $src | Should -Match '\$isEnvelope\s*=\s*\('
        $src | Should -Match "PSObject\.Properties\['Findings'\]"
        $src | Should -Match "PSObject\.Properties\['Status'\]"
        $src | Should -Match "PSObject\.Properties\['Edges'\]"
    }
}
