# Decision: Track F helper modules gap, Option B (consume renderers directly)

## Date
2026-05-13

## Context

Lead plan (`.copilot/audits/lead-track-f-impl-plan-2026-04-23.md` section 2) assumed three standalone helper modules would exist on main before Track F commit 3:

- `modules/shared/EdgeRelations.ps1`
- `modules/shared/Select-ReportArchitecture.ps1`
- `modules/shared/PolicyCoverageAnalyzer.ps1`

Tracks A/B/C/V landed renderers instead of standalone helpers. Atlas's dependency gate (commit 0) correctly flagged the gap. Issue #1056 filed. Commits 1-2 proceeded unblocked (PR #1066, merged).

## Options considered

**Option A:** Extract helper modules from existing renderers into standalone shared files matching the Lead plan's signatures. Refactor renderers to consume the helpers. Higher upfront cost, preserves planned architecture.

**Option B:** Update the Lead plan to consume existing renderer outputs directly. Adjust commit 3+ to match the as-built architecture.

## Decision

Option B. Consume existing renderer and schema surfaces directly. The three "missing" modules are a naming mismatch, not a functionality gap.

Evidence:

1. EdgeRelations enum lives in `modules/shared/Schema.ps1` lines 38-66, exposed via `Get-EdgeRelations` (line 670). Both AttackPathRenderer.ps1 (line 105) and ResilienceMapRenderer.ps1 (line 125) read the canonical values. No standalone file needed.
2. `Select-ReportArchitecture` lives in `modules/shared/ReportManifest.ps1` line 101. Already consumed by `Invoke-AzureAnalyzer.ps1` line 1642 and `modules/shared/Viewer.ps1` line 129. No standalone file needed.
3. PolicyCoverageAnalyzer never existed. Policy gap analysis is covered by `modules/shared/Policy/AlzMatcher.ps1` (ALZ hierarchy fuzzy-match) and `modules/shared/Policy/PolicyEnforcementRenderer.ps1` (Cytoscape graph from policy edges). `Get-AuditorPolicyCoverageSection` consumes these directly.

Cross-renderer edge-filtering duplication is ~10 lines per renderer (each filters by its own relation set). Extracting a shared filter saves trivial lines while adding a dependency and test surface.

## Consequences

- Lead plan commits 3-9 updated: import paths point to Schema.ps1, ReportManifest.ps1, and the Policy/ modules instead of the three phantom files.
- No new shared module PRs needed. Track F slices 2-9 unblocked immediately.
- Atlas owns slice 2+ implementation per routing below.
- The D1 dependency gate in any future multi-track plan must check function names, not file names. File layout may differ from the plan.

## Routing

| Slice | Owner | Consumes |
|---|---|---|
| 2 (control-domain sections) | Atlas | Schema.ps1 `New-FindingRow` ComplianceMappings |
| 3 (attack-path / resilience / policy) | Atlas | AttackPathRenderer.ps1 `New-AttackPathModel`, ResilienceMapRenderer.ps1 `Invoke-ResilienceMapRender`, Policy/AlzMatcher.ps1 + PolicyEnforcementRenderer.ps1 |
| 4-9 | Atlas | No coupling to the three phantom modules |

## References

- Issue: #1056
- Parent epic: #506
- Track F kickoff: #1048
- PR #1066 (slices 0-1, merged)
- Lead plan: `.copilot/audits/lead-track-f-impl-plan-2026-04-23.md`
