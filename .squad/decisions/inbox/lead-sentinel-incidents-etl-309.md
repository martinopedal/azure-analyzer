# Lead drop-box: Sentinel incidents ETL (#309)

Date: 2026-04-21
Owner: Lead

Append-only notes:

- Locked implementation to Schema 2.2 (`97b8277`) and kept `New-FindingRow` as the only normalizer emission path.
- Wrapper now captures MITRE and entity context from incident fields and emits typed fields plus `Pillar`, `ToolVersion`, `Frameworks`, `MitreTactics`, `MitreTechniques`, `DeepLinkUrl`, `EvidenceUris`, and `EntityRefs`.
- Normalizer now passes schema fields through `New-FindingRow` and removes Add-Member extras.
- Added multi-tactic Sentinel fixtures and tests that assert `Merge-FrameworksUnion` behavior through EntityStore when multiple incidents hit the same workspace entity.
