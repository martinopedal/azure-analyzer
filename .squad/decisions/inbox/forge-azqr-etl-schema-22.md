## Forge decision drop, issue #300 azqr Schema 2.2 ETL

- Wrapper now captures azqr `--version` once per run and stamps `ToolVersion` on the envelope and each finding.
- Wrapper projects raw azqr output into stable finding fields, including `RecommendationId`, `Impact`, `Effort`, `DeepLinkUrl`, `Pillar`, `Frameworks`, `MitreTactics`, `MitreTechniques`, `RemediationSnippets`, `EvidenceUris`, `BaselineTags`, and `EntityRefs`.
- Pillar mapping follows azqr taxonomy with canonical WAF values: `Security`, `Reliability`, `CostOptimization`, `PerformanceEfficiency`, `OperationalExcellence`.
- Normalizer now passes Schema 2.2 fields through `New-FindingRow` only, preserving backward-compatible fields and adding `RuleId` from `RecommendationId`.
- Azqr frameworks are normalized to Schema 2.2 tuple shape (`kind`, `controlId`) and include WAF pillar membership.
- Tests expanded with realistic fixture payloads and assertions for every new azqr-emitted Schema 2.2 field.
