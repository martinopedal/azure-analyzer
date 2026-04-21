# Iris Kubescape ETL Schema 2.2 history

## 2026-04-21
- Implemented kubescape wrapper ETL for Schema 2.2 fields: ToolVersion from `kubescape --version`, Pillar set to `Security`, Frameworks with `Name` and `Controls`, MitreTactics, MitreTechniques, and BaselineTags from framework names.
- Updated kubescape normalizer to pass Schema 2.2 fields only through `New-FindingRow`, including EvidenceUris mapped to kubescape control docs and RuleId/Controls from ControlId.
- Added realistic raw kubescape fixture and expanded wrapper plus normalizer tests to verify multi-framework propagation and MITRE pass-through.
