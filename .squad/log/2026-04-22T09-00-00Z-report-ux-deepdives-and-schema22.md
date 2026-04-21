# Session: Report UX Deep-Dives + Schema 2.2 Contract

**Timestamp:** 2026-04-22T09:00:00Z  
**Coordinator** dispatched 6 agents for UX research and report-redesign arc.

## Completed

- 6-agent UX research arc completed:
  - **Iris**: Maester + Kubescape deep-dives with 14-field and 17-field ETL matrices
  - **Atlas**: AzGovViz deep-dive with architecture verdict (single-scroll)
  - **Sage**: azqr/PSRule/Defender/Prowler/Powerpipe deep-dives (v4, 4 refinement turns)
  - **Forge**: Trivy/Infracost/Scorecard deep-dives with ETL matrices
  - **Lead**: WARA/Sentinel deep-dives with per-field ETL tables
  - **Sentinel**: Synthesis, mockup integration, Schema 2.2 contract, 15 issues filed

## Architecture Decision

**Single-page scroll with sticky in-page anchor pills — no JS TabStrip.** Independently reached by Atlas (from AzGovViz analysis) and Sentinel (from mockup experience). Ratified.

## Schema 2.2 Contract

13 new optional `New-FindingRow` fields (all additive, backward-compatible):
`Frameworks`, `Pillar`, `Impact`, `Effort`, `DeepLinkUrl`, `RemediationSnippets`, `EvidenceUris`, `BaselineTags`, `ScoreDelta`, `MitreTactics`, `MitreTechniques`, `EntityRefs`, `ToolVersion`.

EntityStore bumps to v3.2 with `RunContexts` sidecar + `Merge-FrameworksUnion` / `Merge-BaselineTagsUnion` helpers.

## Bugs Uncovered

| Bug | Tool | Severity | Issue |
|-----|------|----------|-------|
| Severity hardcoded to `'Medium'` for all findings | PSRule | High — destroys signal | #301 |
| Score `-1` (errored) mapped to `High` instead of `Info` | Scorecard | Medium | #313 |
| Score `0` (true failure) mapped to `High` instead of `Critical` | Scorecard | Medium | #313 |
| `ImpactedResources[0]` truncation — only first resource kept | WARA | High — breaks effort matrix | #308 |
| `Remediation` = `LearnMoreUrl` aliasing — remediation text lost | WARA | Medium | #308 |
| Missing regulatoryCompliance API call — no framework tags | Defender | High | #302 |
| Raw JSON dump without field projection | azqr | Medium | #300 |

## Issues Filed

- **#299**: Umbrella — Schema 2.2 additive bump
- **#295-#298**: Report generator updates (HTML, MD, exec dashboard, blast-radius)
- **#300-#313**: Per-tool ETL fixes (azqr, PSRule, Defender, Prowler, Powerpipe, Maester, Kubescape, AzGovViz, WARA, Sentinel Incidents, Sentinel Coverage, Trivy, Infracost, Scorecard)

## Samples Updated

- `samples/sample-report.html`: locked design spec (58 KB, single-scroll, framework badges, dark mode)
- `samples/sample-report.md`: markdown twin (13 KB, shields.io badges)

## Next

Per-tool ETL implementation (#300-#313) parallelizable after Schema 2.2 (#299) lands.
