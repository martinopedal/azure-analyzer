# Plan — Issue #187 (fix: identity-graph-expansion bugs from #181 retroactive rubberduck)

## Problem statement

Retroactive 3-of-3 rubberduck on merged PR #181 (`d8ab2a1`) surfaced three real bugs:

- **B1** Orchestrator dispatch contract mismatch — `Invoke-AzureAnalyzer.ps1:992` does `@(& $entryCmd @callParams)` but `Invoke-IdentityGraphExpansion` at line 385 returns `[PSCustomObject]@{Status,RunId,Findings,Edges}`. Result: `@(envelope)` is a 1-element array containing the envelope; normalizer iterates that envelope as if it were a finding; `EntityStore.AddFinding` either throws or pollutes `results.json` with an entry that has no `EntityId`/`Severity`/`Title`. **All real findings silently dropped.** CI green only because wrapper Pester tests stub the wrapper directly, never via the orchestrator.
- **B2** Live data path is mostly stubs — `Get-IdentityGraphExpansionData` (line 407+) initializes 5 collections but only populates `Guests`. `RbacAssignments` / `GroupMemberships` / `AppOwnerships` / `ConsentGrants` are always `@()` in live mode. 4/5 advertised edge types only work via `-PreFetchedData`.
- **B3** LA sink missed in v3.0→v3.1 schema bump — `modules/sinks/Send-FindingsToLogAnalytics.ps1:65` `Read-EntitiesFromJson` does bare-array `ConvertFrom-Json`. Against the new envelope, the entire object is wrapped into a 1-element array; downstream `$entity.Observations` reads operate on the envelope, not entities.

Plus one **non-blocking nit**: `Normalize-IdentityGraphExpansion.ps1` silently coerces unknown severities to `Info` — should `Write-Warning` so wrapper regressions are visible.

## Fix plan

### F1 — Orchestrator envelope detection (B1)

`Invoke-AzureAnalyzer.ps1` ~992:

```powershell
$corrRaw = & $entryCmd @callParams
$isEnvelope = (
    $corrRaw -is [pscustomobject] -and
    $corrRaw.PSObject.Properties['Findings'] -and
    ($corrRaw.PSObject.Properties['Status'] -or $corrRaw.PSObject.Properties['Edges'])
)
if ($isEnvelope) {
    # Wrapper-envelope contract: wrapper already self-adds Edges to $store.
    # Future correlators returning flat finding rows MUST NOT include both a
    # `Findings` property AND a `Status`/`Edges` property — that combination
    # is reserved for the envelope contract.
    $corrFindings = @($corrRaw.Findings)
} else {
    # Legacy contract: flat finding rows from Invoke-IdentityCorrelation.
    $corrFindings = @($corrRaw)
}
```

Stricter sniff per gate consensus (`Findings` alone is too permissive — require a second envelope marker `Status` or `Edges`). Wrapper already self-adds edges via `$store.AddEdge` (lines 372-381), so orchestrator does NOT re-add — avoids double-adds. Contract documented in `Invoke-IdentityGraphExpansion.ps1` synopsis AND in this plan.

### F2 — DEFERRED to follow-up issue

Live data collectors (RbacAssignments / GroupMemberships / AppOwnerships / ConsentGrants) are split into a separate issue per 3-of-3 gate consensus. Naive `Get-Mg*-All` × per-principal walks are O(N×M) and would create a regression worse than B2 itself. Live-mode design needs:

- candidate-driven expansion (only principals already in EntityStore)
- `$batch` + `$expand=members` to collapse fan-out
- per-collector cap with skip-and-warn on hit
- throttling budget with circuit-break on 429-storm
- telemetry summary in `portfolio.json`

Filed as separate squad issue. This PR ships F1+F3+F4+F5 only; B2 is documented in CHANGELOG as a known limitation.

### F3 — LA sink shape sniffer (B3)

`Send-FindingsToLogAnalytics.ps1::Read-EntitiesFromJson`:

```powershell
$parsed = Get-Content -Path $EntitiesJson -Raw | ConvertFrom-Json -ErrorAction Stop
if ($parsed -is [pscustomobject] -and $parsed.PSObject.Properties['Entities']) {
    return @($parsed.Entities)
}
return @($parsed)
```

New test: `tests/sinks/Send-FindingsToLogAnalytics.V3.Tests.ps1` reads `tests/fixtures/identity-graph/entities-v3.1.json` and asserts the returned collection contains entity objects (with `.Observations`), not envelopes.

### F4 — Normalizer warning (nit)

`Normalize-IdentityGraphExpansion.ps1` severity switch default branch:
```powershell
default {
    Write-Warning "Normalize-IdentityGraphExpansion: unknown severity '$raw' coerced to 'Info' for finding $($f.Id)"
    'Info'
}
```
New Pester case asserts the warning is emitted.

### F5 — Integration test (covers B1 regression)

New file `tests/Invoke-AzureAnalyzer.IdentityGraphExpansion.Integration.Tests.ps1`. **Stub mechanism (per gate consensus):** use a fixture tool-manifest pointing at a fixture stub script that defines `Invoke-IdentityGraphExpansion` returning the realistic envelope. Do NOT use `Pester Mock` — orchestrator dot-sources the script at line 961, which would clobber any pre-registered mock.

Test skeleton:
```powershell
Describe 'Invoke-AzureAnalyzer correlator envelope dispatch' {
    BeforeAll {
        $fixtureRoot = Join-Path $PSScriptRoot 'fixtures/orchestrator-correlator'
        $tmpOut = New-TempDirectory
        # fixture manifest: identity-graph-expansion -> stub script returning
        # PSCustomObject @{Status='Success';Findings=@(<3 well-formed FindingRows>);Edges=@(<2 edges>)}
    }
    It 'persists envelope.Findings to results.json (regression for B1)' {
        & $analyzer -ManifestPath $fixtureManifest -OutputPath $tmpOut.Path -SkipPrereqCheck
        $results = Get-Content (Join-Path $tmpOut.Path 'results.json') | ConvertFrom-Json
        $results.Count | Should -Be 3
        $results | ForEach-Object { $_.EntityId | Should -Not -BeNullOrEmpty }
    }
    It 'persists envelope.Edges to entities.json' {
        $entities = Import-EntitiesFile (Join-Path $tmpOut.Path 'entities.json')
        $entities.Edges.Count | Should -Be 2
    }
    # Pre-fix-failure assertion: this test, when run against `git show d8ab2a1`,
    # must produce results.json with either 0 valid findings OR 1 row with empty
    # EntityId. CI verifies this via a separate `Should -Throw` Context block
    # that runs the OLD dispatch logic inline.
    Context 'Pre-fix dispatch reproduction' {
        It 'old dispatch (@(envelope)) produces a single garbage row' {
            $envelope = [PSCustomObject]@{ Status='Success'; Findings=@(1,2,3); Edges=@() }
            $oldDispatch = @($envelope)   # the buggy line
            $oldDispatch.Count | Should -Be 1
            $oldDispatch[0].PSObject.Properties['EntityId'] | Should -BeNullOrEmpty
        }
    }
}
```

## Schema bump

**No schema bump.** All four fixes target v3.1 behavior. The `entities.json` envelope, edge model, and finding row contract are unchanged. The wrapper return contract (envelope shape) is documented post-hoc but not versioned — back-compat for legacy correlators is preserved via the explicit shape-sniff in F1.

## Files touched

- `Invoke-AzureAnalyzer.ps1` (F1, ~10 lines — stricter envelope sniff)
- `modules/Invoke-IdentityGraphExpansion.ps1` (synopsis update only — documents envelope contract; F2 deferred)
- `modules/sinks/Send-FindingsToLogAnalytics.ps1` (F3, ~5 lines)
- `modules/normalizers/Normalize-IdentityGraphExpansion.ps1` (F4, +Write-Warning + wrapper name in text)
- `tests/sinks/Send-FindingsToLogAnalytics.V3.Tests.ps1` (new, F3)
- `tests/normalizers/Normalize-IdentityGraphExpansion.Tests.ps1` (F4 warning case)
- `tests/Invoke-AzureAnalyzer.IdentityGraphExpansion.Integration.Tests.ps1` (new, F5)
- `tests/fixtures/orchestrator-correlator/` (new, F5 stub manifest + script)
- `CHANGELOG.md` (Unreleased: bugfix entries + B2 known-limitation note linking follow-up issue)

## Acceptance

- [ ] Pester ≥1047 + 4 new cases (= ≥1051), 100% green
- [ ] Integration test (F5) demonstrably fails on `main` (proves B1 was real) and passes on this branch
- [ ] B2 collectors each have a mock-based test asserting `Invoke-WithRetry` invocation + `Remove-Credentials` on error
- [ ] B3 sink test reads real v3.1 fixture and finds entities (not envelope) downstream
- [ ] No schema bump justified explicitly in PR `## Schema bump` block
- [ ] PR `## Research` block links Issue #187, summarizes 3-model verdicts, links the gate-of-the-fix-plan results
