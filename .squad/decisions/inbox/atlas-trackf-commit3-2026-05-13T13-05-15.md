# Track F Commit 3 - Attack-Path, Resilience, Policy-Coverage Sections

**Date:** 2026-05-13  
**Agent:** Atlas (Squad Core Dev)  
**PR:** #1090  
**Epic:** #506 (Track F - Auditor-driven report builder)  
**Plan ref:** `.copilot/audits/lead-track-f-impl-plan-2026-04-23.md` § 5

## What landed

Implemented three Track A/B/C consumer functions:

1. **`Get-AuditorAttackPathSection`**
   - Queries attack-path edges from `entities.edges` array
   - Attack-path relation types consumed from `EdgeRelations` enum in `modules/shared/Schema.ps1` (line 38): `HasFederatedCredential`, `AuthenticatesAs`, `UsesSecret`, `HasRoleOn`, `DeploysTo`, `TriggeredBy`
   - Tier-aware rendering mode: inline (Tier 1/2), paginated (Tier 3), deepLink (Tier 4)
   - Returns `TotalPaths`, `CriticalPaths`, `RenderingMode`, optional `HtmlSnippet`/`DeepLinkUrl`
   - Cytoscape HTML emission stubbed as placeholder for inline mode

2. **`Get-AuditorResilienceSection`**
   - Reads `blastRadiusScore` from entity properties
   - Computes top 10 resources sorted descending by score
   - Returns `TopResources[]`, `TotalEntities`, `RenderingMode`
   - Gracefully skips entities without blast-radius scores

3. **`Get-AuditorPolicyCoverageSection`**
   - Reads `policyGaps` array from `entities.json` (Track C output)
   - Generates AzAdvertizer deep links per policy ID
   - Returns `AssignedCount`, `MissingCount`, `GapSuggestions[]`, `AzAdvertizerLinks[]`
   - Policy link format: `https://www.azadvertizer.net/azpolicyadvertizer/<policyId>.html`

## Fixture changes

Extended `tests/fixtures/auditor-small/entities.json`:

**Entities added (10 Azure resources):**
- vm-prod-01 (score 85.5), vm-prod-02 (72.3)
- kv-prod-01 (95.2), stprod01 (88.7), sql-prod (91.4)
- nsg-prod (65.8), app-prod (55.3), vnet-prod (78.9)
- disk-prod-01 (60.2), pip-prod (45.6)

**Edges added (8 edges):**
- 5 attack-path relations: `HasFederatedCredential` (2), `AuthenticatesAs` (1), `UsesSecret` (1), `HasRoleOn` (1)
- 3 resilience relations: `DependsOn` (2), `FailsOverTo` (1)

**Policy gaps added:**
- 3 missing policies: SQL Auditing, VM DR, Key Vault purge protection

## Tests added

Five new tests in `tests/shared/AuditorReportBuilder.Tests.ps1` (numbered 8-12):
1. **Test 8:** attack-path count from entities.json (validates TotalPaths = 5)
2. **Test 9:** tier-aware rendering mode (inline for Tier 1, deepLink for Tier 4)
3. **Test 10:** top 10 resources by blast-radius (validates sorting + count)
4. **Test 11:** identifies missing policies (validates MissingCount, GapSuggestions)
5. **Test 12:** includes AzAdvertizer deep links (validates link format)

**Result:** 12/12 tests passing (4 Commit 1 + 3 Commit 2 + 5 Commit 3).

## How Track A/B/C surfaces were consumed

Per Lead's Option B verdict (#1056):

- **EdgeRelations enum:** Confirmed in `modules/shared/Schema.ps1` line 38. Attack-path relations extracted directly from enum values (no separate module).
- **Policy modules:** Confirmed at `modules/shared/Policy/AlzMatcher.ps1` and `modules/shared/Policy/PolicyEnforcementRenderer.ps1`. Functions exist (`Invoke-AlzHierarchyMatch`, `New-PolicyEnforcementGraph`, `Get-PolicySuggestionsForFinding`) but NOT directly called by this commit. Policy-coverage section reads `policyGaps` array from `entities.json` per Track C output convention (standard v3 entity schema extension).
- **Track C output format:** Assumed `policyGaps` array in `entities.json` per v3 entity schema pattern. Actual Track C implementation will populate this field when it lands.

No extraction or wrapper creation required - consumed as-built per Option B.

## Plan deviations

**None.** Plan spec matched implementation. EdgeRelations enum at expected location, policy modules at expected location, Track C output format assumed per v3 schema conventions.

## Commit

`0fea742` - feat(report): implement attack-path, resilience, and policy-coverage sections

## Next steps

Commit 4 (Triage Annotations consumer) - blocked until Commit 3 merges. Plan ref § 6.
