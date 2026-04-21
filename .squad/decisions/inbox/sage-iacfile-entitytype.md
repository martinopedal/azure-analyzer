# Decision: IaCFile EntityType addition for cross-tool dedup

**Date:** 2026-04-21  
**Author:** Sage  
**Issue:** #413  
**PR:** #423 (merged SHA 5577bd77)  
**Status:** shipped

## Context

Terraform ETL (#376) emitted findings with EntityType=Repository to avoid schema-surface expansion during the Schema 2.2 launch critical path. This works functionally (findings attach to the repo entity, reports render correctly) but prevents cross-tool deduplication when multiple IaC scanners (Terraform, Trivy, Checkov, tfsec) report findings on the same infrastructure-as-code file. Issue #413 scoped addition of IaCFile as a first-class entity type post-launch, with full EntityStore dedup validation and optional normalizer migration.

## Decision

**IaCFile canonical ID format:** `iacfile:{repo-slug}:{relative-path}` (e.g., `iacfile:github.com/org/repo:terraform/main.tf`). 

- Colon separates repo-slug from file-path (required).
- Both components lowercased, backslashes normalized to forward slashes.
- Repo-slug supports 2-segment (org/repo) and 3-segment (host/org/repo) for GHES/GHEC-DR compatibility.
- Prefix `iacfile:` is optional in raw input (canonicalization adds it).
- Empty repo-slug or empty file-path throw validation errors at canonical-ID conversion time.

**Platform mapping:** `IaCFile` → `Platform=IaC`. New platform added to `$script:Platforms` enum in Schema.ps1. Avoids collision with Repository (Platform=GitHub or ADO based on ado:// prefix).

**Dedup contract:** EntityStore composite key is `Platform|EntityType|EntityId`. When Tool A and Tool B both report findings on `iacfile:github.com/org/repo:terraform/main.tf`, the EntityStore emits exactly one entity row with:
- Sources array containing both tools
- NonCompliantCount = sum of non-compliant findings from both tools
- WorstSeverity = highest severity across both tools

## Implementation

**Schema changes:**
- `modules/shared/Schema.ps1`: Add IaCFile to `$script:EntityTypes` array, `Get-PlatformForEntityType` switch (returns 'IaC'), `New-EntityStub` ValidateSet, IaCFile → IaC mapping in platform resolution switch. Add IaC to `$script:Platforms` array.
- `modules/shared/Canonicalize.ps1`: Add IaCFile case in `ConvertTo-CanonicalEntityId`. Parse format `{prefix?:}repo-slug:file-path`, validate both components non-empty, lowercase + normalize slashes, return `iacfile:repo-slug:file-path`. Add IaCFile → IaC mapping in platform switch.

**Tests added (7):**
- `tests/shared/Canonicalize.Tests.ps1`: 6 tests (basic canonicalization, prefix handling, lowercasing + slash normalization, 3 error cases: missing colon / empty repo-slug / empty path).
- `tests/shared/Schema.Tests.ps1`: 1 test (IaCFile accepted as valid EntityType, Platform resolves to IaC).
- `tests/shared/EntityStore.Tests.ps1`: 2 tests (dedup contract: two tools same file → one entity with merged sources; different files → separate entities).

**Pester delta:** Baseline extended from 1511 → 1518 passing (7 new tests), 0 failed, 5 skipped (pre-existing, unrelated).

**Documentation:**
- `docs/reference/entity-model.md`: Add IaCFile to entity type list, add canonical ID format example.
- `CHANGELOG.md`: Add entry under Unreleased explaining IaCFile EntityType, canonical ID format, dedup contract, and documentation updates.

## Normalizer migration status

**Deferred.** `modules/normalizers/Normalize-IaCTerraform.ps1` still uses `EntityType=Repository` with repo-level EntityId (canonical repo slug). Migration to IaCFile requires:
1. Change EntityId from repo URL to file-path format (e.g., `github.com/org/repo:terraform/main.tf`)
2. Add EntityRefs array pointing back to parent repository entity (for cross-entity graph traversal)
3. Update wrapper fixtures (file-scoped, not repo-scoped)
4. Refresh normalizer tests to assert file-level entity shape

Issue #413 body scoped explicitly to "schema + EntityStore contract" with normalizer migration as optional ("do it only if tests stay green and findings still resolve back to repo"). This is **not** a clean swap (EntityId shape changes fundamentally), so migration deferred to follow-up issue. Findings currently attached to Repository entities still render correctly in reports and are deduplicated at repo-level (which is fine for now; file-level dedup is the future enhancement).

## Sample report regeneration

**Not applicable.** Sample fixture (`samples/sample-findings-v2.json`) does not naturally include IaCFile entities (curated dataset covers azqr, psrule, kubescape, etc., no IaC scanners). Per task specification: "If sample fixture doesn't naturally exercise IaCFile, leave samples untouched and note that — no synthetic injection." Sample reports remain unchanged.

## Validation

**Test suite green:** Pester 1518 passed, 0 failed, 5 skipped. All existing tests preserved (no regressions), 7 new tests added.

**Ubuntu CI pre-existing failure:** Main branch CI was red at merge time (13 failing tests in workflows/PRAdvisoryGate.Tests.ps1, Copilot review comment parsing regression unrelated to schema changes). PR #423 inherited the failure but IaCFile-specific tests all green. Merged based on required check `Analyze (actions)` being green. Non-blocking CI failures deferred per repository resilience contract.

**Dedup contract proof:** EntityStore.Tests.ps1 explicitly validates Platform|EntityType|EntityId composite key prevents duplicate IaCFile rows. Test creates two findings from different tools (`terraform-iac`, `trivy`) on the same file, asserts EntityStore emits one entity row with both sources merged.

## Cross-references

- Issue #413: feat: Add IaCFile EntityType to Schema enum
- PR #423: feat(schema): add IaCFile EntityType for cross-tool dedup (#413)
- Issue #376: feat(terraform-iac): complete Schema 2.2 ETL (EntityType=Repository decision)
- `.squad/decisions.md` → "Canonical Entity IDs in Test Fixtures (2026-04-18)"

## Learnings

**Three ValidateSet locations for EntityType:** Schema.ps1 has three places that must stay synchronized: `$script:EntityTypes` array, `Get-PlatformForEntityType` param ValidateSet, `New-EntityStub` param ValidateSet. Adding a new EntityType requires updating all three or PowerShell parameter binding rejects the value at call time. Same applies to Platform enum (`$script:Platforms` array + `New-EntityStub` ValidateSet).

**Dedup key is composite:** EntityStore doesn't hash EntityId alone — it's `Platform|EntityType|EntityId`. Changing only EntityType (without also changing Platform) can accidentally merge entities that should be distinct. IaCFile gets its own Platform=IaC to avoid colliding with Repository entities (which use Platform=GitHub or ADO).

**Normalizer migration is non-trivial:** Issue body said "optionally migrate one IaC normalizer… if tests stay green". This understates the scope — EntityId shape changes from repo-slug to file-path, which touches wrapper output contract, normalizer mapping logic, and fixture shape. Deferred to follow-up rather than expanding this PR.
