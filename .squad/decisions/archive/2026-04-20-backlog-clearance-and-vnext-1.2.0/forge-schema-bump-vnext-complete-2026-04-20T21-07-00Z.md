# Forge: schema-bump vNEXT (Stage 1) complete

**PR:** #281  
**Merge SHA:** 2e215b2  
**Merged:** 2026-04-20T21:06:01Z  
**Closes:** #228 (auto-closed)

## Schema delta shipped

- ``: `2.0` -> **`2.1`** (additive)
- `New-FindingRow`: new optional `[string]  = ''` parameter, positioned between `Title` and `Compliant`; emitted as `RuleId` field on the row PSCustomObject between `Title` and `Severity`.
- `EntityType` enum: 14 -> **16** members (added `AdoProject`, `KarpenterProvisioner`).
  - `Get-PlatformForEntityType`: AdoProject -> ADO, KarpenterProvisioner -> Azure.
  - `ConvertTo-CanonicalEntityId` (Canonicalize.ps1): AdoProject canonicalized inline as `ado://{org}/{project}` (2-segment, distinct from 4-segment `ConvertTo-CanonicalAdoId`); KarpenterProvisioner delegates to `ConvertTo-CanonicalArmId`.

## Reports

- HTML: link label `Fix it` was already in place from #275/#229; no code change.
- MD: `New-MdReport.ps1` column header `Learn More` -> `Fix it` in all four tables. `samples/sample-report.{md,html}` regenerated. Field name `LearnMoreUrl` unchanged - presentational only.

## Permissions

`PERMISSIONS.md` gained an **Opt-in elevated RBAC tier** section scaffolding the Karpenter inspection contract: default Reader-only, off-by-default opt-in to `Azure Kubernetes Service Cluster User Role` per AKS managed cluster. Mechanism implementation lands with #234.

## CHANGELOG

New `[1.2.0 - Unreleased]` section above existing `[Unreleased]`.

## Backward compat

- `RuleId` is optional with `''` default - all existing call sites work unchanged.
- `Test-FindingRow` does not enforce literal version equality - readers pinned to 2.0 still parse 2.1 records.
- `AzureAnalyzer.psd1` ModuleVersion stays at `1.0.0` (per spec; module bump is a separate PR).
- HTML `Get-FindingRuleKey` already had title-prefix fallback for findings without `RuleId`.

## Tests

Baseline 1294 -> **1302 passed, 0 failed, 5 skipped** (+8 net new).

- `tests/shared/Schema.Tests.ps1`: +4 (RuleId default, RuleId persisted, AdoProject, KarpenterProvisioner) + `Get-PlatformForEntityType` describe block.
- `tests/reports/Collapsible-Tree.Tests.ps1`: +1 (RuleId beats title-prefix as level-3 grouping key).
- 17 normalizer/shared test files: SchemaVersion `'2.0'` -> `'2.1'` assertions.

## CI

All 15 required + advisory checks green on first run. `Analyze (actions)`, `Tool catalog fresh`, `Permissions pages fresh`, `Test (windows/ubuntu/macos)`, `Documentation update check` all pass. Merged `--admin --squash --delete-branch`; remote branch deleted, local branch + worktree cleaned.

## Stage 2 dispatch readiness

Unblocked - ready to dispatch in parallel:

- **#227** (RuleId-based rule quality): consume new `RuleId` field on `New-FindingRow`; no further schema work required.
- **#232** (AdoProject EntityType consumers): `EntityType=AdoProject` + `Platform=ADO` available; canonical form `ado://{org}/{project}`.
- **#234** (Karpenter wrapper + opt-in RBAC mechanism): `EntityType=KarpenterProvisioner` + `Platform=Azure` available; PERMISSIONS.md contract scaffolded - implementer needs to wire the opt-in toggle (e.g., `-EnableKarpenterInspection` flag or manifest opt-in field).

## Notes / open items for coordinator

- **Brady's decision file `coordinator-brady-vnext-decisions-2026-04-20T22-48-04Z.md` was NOT present in `.squad/decisions/inbox/`** when work began. Implementation proceeded against the spec embedded in the dispatch prompt. If the decision doc still exists elsewhere (drafts, comments), recommend dropping it in inbox for audit-trail hygiene before dispatching Stage 2.
- `RuleId` was already used informally via `Add-Member` in `Normalize-FinOpsSignals.ps1` and consumed by `New-HtmlReport.ps1::Get-FindingRuleKey` and `FrameworkMapper.ps1` - this PR just promotes it to a first-class schema field. Pre-existing `Add-Member` call sites continue to work.
