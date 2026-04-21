# Forge update - Prowler ETL #303

- Date: 2026-04-21
- Scope: Added Prowler wrapper + normalizer pipeline to Schema 2.2 with tests and manifest wiring.
- Wrapper: captures ToolVersion, Pillar, Frameworks, BaselineTags, MITRE fields, remediation snippets, and deep link URL from Prowler output.
- Normalizer: emits via `New-FindingRow`, canonical ARM EntityId, and `EvidenceUris` from `ResourceArn`.
- Tests: added wrapper + normalizer suites and realistic multi-framework fixtures; includes framework union assertion with `Merge-FrameworksUnion`.
