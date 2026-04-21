# forge decision drop - gh-actions-billing schema 2.2 etl

Issue: #366
Date: 2026-04-21

## Decisions
- Upgraded wrapper and normalizer to emit and normalize Schema 2.2 cost metadata fields for gh-actions-billing.
- Standardized RuleId tags to GHA-PaidMinutesExceeded, GHA-RunAnomaly, GHA-TopConsumer, and GHA-BudgetOverage for baseline tagging consistency.
- Set Pillar to Cost Optimization on every gh-actions-billing finding.
- Added ScoreDelta for minute overage, anomaly delta, top consumer minutes, and budget overrun (USD).
- Added Impact heuristic (High/Medium/Low) based on paid minute ratio, budget overrun USD, and minute deltas.
- Added EvidenceUris, DeepLinkUrl, EntityRefs, RemediationSnippets, BaselineTags, and ToolVersion to findings.
- Kept Frameworks and MITRE fields empty for gh-actions-billing per issue guidance.
- Extended EntityStore merge behavior to union Schema 2.2 arrays and metadata without duplicate finding rows.

## Validation
- Targeted tests: Invoke-GhActionsBilling, Normalize-GhActionsBilling, EntityStore tests all green.
- Full suite: Invoke-Pester -Path .\tests -CI green.
