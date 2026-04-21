# Lead decision: aks-rightsizing Schema 2.2 ETL

Date: 2026-04-21
Issue: #364
Owner: Lead

## Decisions

1. Wrapper emits Schema 2.2 metadata at source for each finding: Pillar, Impact, Effort, DeepLinkUrl, RemediationSnippets, EvidenceUris, BaselineTags, ScoreDelta, EntityRefs, ToolVersion.
2. Normalizer maps all emitted fields into New-FindingRow and keeps Frameworks, MitreTactics, and MitreTechniques empty for this tool.
3. Workload entity identity is stable and deterministic: cluster resourceId + namespace + workload name. This allows EntityStore union merge to combine multi-category findings on the same workload.
4. ScoreDelta follows workload signal percent (waste for overprovisioned, saturation for underprovisioned and failure categories).
5. BaselineTags include category and metric forms for downstream filtering.

## Validation

- Targeted Pester suites for wrapper and normalizer are green.
- Full Pester suite is green after changes.
