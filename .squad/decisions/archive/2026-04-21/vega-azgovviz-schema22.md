# Vega decision: azgovviz Schema 2.2 upgrade (#401)

## Decision
Implement Schema 2.2 field coverage for AzGovViz end-to-end in both wrapper and normalizer.

## Scope completed
- Wrapper enriches findings with Frameworks (ALZ and CAF), Pillar, Impact, Effort, DeepLinkUrl, RemediationSnippets, EvidenceUris, BaselineTags, and ToolVersion.
- Normalizer maps Schema 2.2 fields through New-FindingRow, including ScoreDelta, MitreTactics, MitreTechniques, and EntityRefs.
- BaselineTags now include policy category tag derivation.
- Added fixture-backed assertions for new fields in wrapper and normalizer tests.
- Verified EntityStore dedup behavior remains unchanged for subscription and management group entities.

## Validation
- Targeted tests: Invoke-AzGovViz + Normalize-AzGovViz passed.
- Full suite: Invoke-Pester -Path .\tests -CI passed (1495 passed, 0 failed, 5 skipped).
