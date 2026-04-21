# Sage WARA ETL Log

## 2026-04-22
- Implemented WARA wrapper ETL updates for issue #308.
- Wrapper now captures ToolVersion from `Get-Module WARA`.
- Wrapper invokes collector plus analyzer and reads `Expert-Analysis-*.xlsx` metadata when available.
- Emission now preserves all impacted resources by outputting one finding per resource.
- Added v1 finding fields required for Schema 2.2 normalization: `Pillar`, `RecommendationId`, `Impact`, `Effort`, `DeepLinkUrl`, `BaselineTags`, `RemediationSteps`, `EntityRefs`, and `ToolVersion`.
- Normalizer now emits Schema 2.2 fields via `New-FindingRow` including `Frameworks`, `Pillar`, `Impact`, `Effort`, `DeepLinkUrl`, `RemediationSnippets`, `BaselineTags`, `EntityRefs`, and `ToolVersion`.
- Added tests for wrapper success path and normalizer assertions, including full WAF pillar coverage for Reliability, Security, Cost, Performance, Operational.
