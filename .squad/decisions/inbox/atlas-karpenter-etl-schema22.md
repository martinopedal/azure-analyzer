# Atlas decision: aks-karpenter-cost Schema 2.2 ETL

## Context
Issue #365 required end-to-end Schema 2.2 enrichment for aks-karpenter-cost wrapper and normalizer, while preserving entity and finding dedup behavior.

## Decisions
- Wrapper now emits Schema 2.2 fields for each finding: Pillar, Impact, Effort, DeepLinkUrl, RemediationSnippets, EvidenceUris, BaselineTags, ScoreDelta, EntityRefs, ToolVersion.
- Pillar is Cost Optimization by default, with Cost Optimization; Reliability for consolidation-disabled risk.
- Impact maps from NodeHours and ObservedPercent thresholds, with high impact for no-node-limit.
- Effort is Low for reader telemetry findings and Medium for provisioner remediation actions.
- Deep links use Microsoft_Azure_ContainerService portal blade URLs.
- Evidence URIs include Container Insights query links and Karpenter manifest API URIs.
- ToolVersion is stamped as kubectl plus Karpenter API version when available.
- EntityStore metadata merge now uses Merge-FrameworksUnion and Merge-BaselineTagsUnion to keep Schema 2.2 union semantics stable.

## Validation
- Targeted Pester suites for wrapper, normalizer, and EntityStore passed.
- Full Pester run passed with existing non-fatal warning baseline.
