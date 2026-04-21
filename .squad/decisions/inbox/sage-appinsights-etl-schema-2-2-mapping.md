# Sage decision: appinsights schema 2.2 ETL

Date: 2026-04-21
Issue: #362

## Decision
Implement Schema 2.2 mapping in both wrapper and normalizer for appinsights findings.

## Mapping
- Pillar from QueryType: requests and dependencies => PerformanceEfficiency, exceptions => Reliability.
- BaselineTags include query family tag and metric category tag.
- DeepLinkUrl uses Azure Portal AnalyticsBlade links with KQL and timespan.
- EvidenceUris includes overview link and analytics deep link.
- Impact and Effort use count and latency heuristics.
- ScoreDelta uses latency baseline delta when available, otherwise AvgDurationSeconds.
- EntityRefs include component ResourceId and parent App Service refs from hidden-link tags.
- ToolVersion comes from Az.ApplicationInsights module version with az CLI fallback.

## Entity dedup guardrail
Keep entity identity on Platform|EntityType|EntityId and finding identity on Source|EntityId|Title|Compliant. Update EntityStore merge logic to union Frameworks and BaselineTags for duplicate findings.
