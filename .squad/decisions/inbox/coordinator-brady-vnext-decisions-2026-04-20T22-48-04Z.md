# Brady decisions on schema/policy questions (vNEXT 1.2.0 stream)

Date: 2026-04-20T22-48-04Z

Closing the 6 blocking questions Lead surfaced in the AKS/reports/cost backlog triage.

## Decisions

| # | Question | Decision |
|---|---|---|
| 1 | #227 RuleId | YES, add `[string] ` to `New-FindingRow` |
| 2 | #228 URL field | REUSE LearnMoreUrl (presentational rename to ""Fix it"" in HTML report column) |
| 3 | #232b/#234b new EntityTypes | YES BOTH (AdoProject + KarpenterProvisioner added to enum) |
| 4 | #234b elevated RBAC | YES opt-in tier (`Azure Kubernetes Service Cluster User Role` allowed only when user explicitly enables) |
| 5 | vNEXT 1.2.0 cutoff | All four features (#227, #228, #232, #234) ship targeting 1.2.0 (do NOT gate 1.1.0) |

## Execution shape

Stage 1 (must land first): Forge ships Schema bump PR
- Schema.ps1: add `RuleId` field on FindingRow, add AdoProject + KarpenterProvisioner to EntityType enum
- modules/shared/Permissions.ps1 (or canonical equivalent): document opt-in elevated RBAC tier
- HTML report: rename ""Learn more"" column to ""Fix it"" (presentational, field name unchanged)
- CHANGELOG: under new ## [1.2.0 - Unreleased] section
- Pester baseline 1294 must extend, not break

Stage 2 (parallel after Stage 1):
- Sentinel #227 top-recs panel (uses RuleId)
- Atlas #232 CI/CD cost telemetry (uses AdoProject)
- Atlas #234 AKS runtime cost (uses KarpenterProvisioner + opt-in RBAC)

#228 is satisfied by the Stage 1 column rename; close as completed by Stage 1 PR.
