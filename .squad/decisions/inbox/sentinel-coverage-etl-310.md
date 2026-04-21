# Sentinel Coverage ETL Drop

## 2026-04-21

- Implemented Schema 2.2 ETL for `sentinel-coverage` across wrapper and normalizer.
- Wrapper now emits `ToolVersion`, `Pillar`, `DeepLinkUrl`, `Frameworks`, `MitreTactics`, and `MitreTechniques`.
- Normalizer now maps those fields through `New-FindingRow` and sets workspace `EntityRefs`.
- Extended fixture and tests to verify MITRE technique IDs flow end-to-end.
