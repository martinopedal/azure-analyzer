# Atlas Decision - Track F Commit 8: Report-Manifest Profile Extension

**Date:** 2026-05-13  
**Agent:** Atlas (Squad Core Dev)  
**Context:** Track F implementation (issue #506) - Commit 8 of 9  
**Status:** IMPLEMENTED

---

## Decision: Extend New-ReportManifest with Auditor Profile Block

**What:** Add `-Profile` and `-Sections` parameters to `New-ReportManifest` in `modules/shared/ReportManifest.ps1`. When `-Profile Auditor`, append a Profile block to the manifest containing section metadata and a filtered subset of degradations matching those sections (Declared Degradation Contract).

**Why:** The auditor-driven report builder (`Build-AuditorReport`) needs to persist its profile metadata alongside the standard report manifest. This allows:
1. Report consumers to detect which profile generated the report
2. Section-specific degradation tracking (Track A/B/C data missing, tier downgrades)
3. Contract enforcement: every degradation in the auditor profile MUST reference a real section ID

This is the "manifest extension" phase of Track F, bridging the orchestrator (Commit 7) to the final documentation phase (Commit 9).

---

## Implementation

### New Parameters

Added 2 optional parameters to `New-ReportManifest`:
- `[ValidateSet('Default', 'Auditor')] [string] $Profile = 'Default'`
- `[object[]] $Sections = @()`

### Profile Block Logic

When `$Profile -eq 'Auditor'`:
1. Extract section IDs from `$Sections` (supports both `.Id` and `.id` properties for robustness)
2. Filter global `$degradations` array to include only degradations whose `name` property matches a section ID
3. Construct Profile block: `@{ Name='auditor'; Sections=$Sections; Degradations=$profileDegradations }`
4. Add Profile block to manifest via `Add-Member`

When `$Profile -eq 'Default'`: no Profile block added (backward compatible)

### Test Coverage

Added 4 new tests in `Describe 'New-ReportManifest -Profile Auditor'`:
1. **Appends Profile block when -Profile Auditor** - verifies Profile.Name='auditor', Sections array, and first section ID
2. **Every section in Profile has renderingMode property** - enforces section schema contract
3. **Every Profile.Degradations entry references a real section id (Declared Degradation Contract)** - critical contract enforcement test
4. **Does not append Profile block when -Profile Default** - backward compatibility check

Total tests: 18 (14 existing + 4 new)

---

## Rationale

**Why add Profile to the manifest?** Per Track F design doc section 8, the auditor profile is a first-class report variant, not a post-processing transformation. The manifest is the single source of truth for "how this report was generated" - profile metadata belongs there.

**Why filter degradations?** Global degradations include features that may not be in the auditor profile (e.g., standard report features). Including all degradations in the Profile block would pollute the auditor manifest with irrelevant entries. Filtering ensures the Profile.Degradations array is a precise, auditor-scoped subset.

**Why the Declared Degradation Contract?** Per Lead's plan (Commit 8 spec), orphan degradations (degradations that reference non-existent section IDs) indicate a logic bug. The contract test (test #3) enforces this invariant at CI time, catching wrapper/normalizer regressions before they reach production.

**Why support both `.Id` and `.id`?** PowerShell property names are case-insensitive at runtime, but explicit property checks via `.PSObject.Properties['Id']` are case-sensitive. Supporting both patterns makes the function robust against callers using either casing convention.

---

## Alternatives Considered

**Alt 1: Store profile metadata in a separate `profile-manifest.json` file** - REJECTED because it violates the single-source-of-truth principle. The manifest already tracks tier, features, degradations, and policy metadata; profile is the same category of metadata.

**Alt 2: Always include Profile block, default to Name='standard'** - REJECTED because it breaks backward compatibility. Existing consumers expect the manifest schema without a Profile property. Conditional inclusion (only when `-Profile Auditor`) preserves back-compat.

**Alt 3: Omit degradations from Profile block, rely on global Degradations array** - REJECTED because it doesn't support profile-specific degradation scoping. A degradation in the global array might reference a feature that's irrelevant to the auditor profile (e.g., interactive graph canvas degrading to summary mode in Tier 4, but auditor profile uses static tables).

---

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Profile block schema changes break consumers | LOW | MEDIUM | Profile is new in Track F; no existing consumers yet. Schema versioning via `SchemaVersion` field already in place. |
| Degradation filter logic bug (orphans) | MEDIUM | HIGH | Test #3 enforces contract at CI time. No orphans allowed. |
| Case-sensitivity mismatch on section ID lookup | LOW | MEDIUM | Support both `.Id` and `.id` properties. Document convention in Track F final docs (Commit 9). |

---

## Acceptance Criteria

- [x] New-ReportManifest accepts `-Profile` and `-Sections` parameters
- [x] Profile block appended when `-Profile Auditor`
- [x] Profile block omitted when `-Profile Default`
- [x] Profile.Degradations filtered to section IDs only
- [x] Test coverage: 18 total (14 existing + 4 new), all green
- [x] Declared Degradation Contract test enforces no orphan degradations
- [x] No line-ending flips (verified via `git diff --cached -w --numstat`)

---

## Lessons Learned

**Line-ending preservation:** PowerShell `Set-Content` with `-NoNewline` preserves line endings when using `-Raw` input from `Get-Content -Raw`. The repository stores LF for `.ps1` files (verified via hex dump showing `0A` not `0D 0A`). Earlier sessions encountered CRLF-to-LF flips when using the `edit` tool; this session used PowerShell string replacement to avoid editor interference.

**Property case-sensitivity:** `.PSObject.Properties['PropertyName']` is case-sensitive even though PowerShell property access (`$obj.PropertyName`) is case-insensitive. Defensive coding pattern: check both `.Id` and `.id` when the caller's casing convention is unknown.

---

## Next Steps

**Commit 9 (final):** Documentation update (README, PERMISSIONS, CHANGELOG) + parity test + close issue #506. Profile manifest extension is now complete; orchestrator wiring (Commit 7) can pass `-Profile Auditor -Sections $sections` to `New-ReportManifest` and persist the profile metadata.

---

## References

- Issue #506: Track F implementation (auditor-driven report redesign)
- Lead plan: `.squad/decisions/inbox/lead-track-f-impl-plan-2026-04-23.md`
- Design doc: `docs/design/track-f-auditor-redesign.md` section 8 (manifest extension)
- Commit 7: Orchestrator wiring + nav chip (PR #1094)
- Commit 9: Final documentation + parity test (pending)
