# Atlas decision - azure-quota Schema 2.2 ETL

Date: 2026-04-21
Issue: #360

## Decision
Use stable AzureResource entity IDs per subscription + location + service for azure-quota normalized findings.

## Why
EntityStore dedup keys on Platform|EntityType|EntityId. Quota emits many metric rows for the same service in the same region. A stable combo entity ID keeps one entity row per quota surface while preserving per-metric finding rows.

## Applied mapping
- Pillar: Reliability
- Impact from UsagePercent: High >= 90, Medium >= 75, Low < 75
- Effort heuristic: vm -> Medium, network -> Low
- ScoreDelta: UsagePercent
- DeepLinkUrl: Azure Portal quota blade with subscription, region, service
- EvidenceUris: quota docs by service
- EntityRefs: subscriptionId and location
- ToolVersion: azure-cli version from `az version`
- Frameworks, MITRE, BaselineTags: intentionally empty
