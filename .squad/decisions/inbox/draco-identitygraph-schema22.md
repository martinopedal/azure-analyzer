# Decision: issue #404 schema 2.2 identity graph ETL

- Owner: draco
- Issue: #404
- Branch: `feat/404-identitygraph-schema22`

## Decision

Upgrade `identity-graph-expansion` wrapper and normalizer end to end for Schema 2.2 identity metadata and graph-aware references.

## Implemented

- Wrapper now emits Schema 2.2 fields through `New-FindingRow`: `Frameworks`, `Pillar`, `Impact`, `Effort`, `DeepLinkUrl`, `RemediationSnippets`, `EvidenceUris`, `BaselineTags`, `MitreTactics`, `MitreTechniques`, `EntityRefs`, and `ToolVersion`.
- MITRE mappings include `TA0008` and `TA0004` with techniques on all identity graph risk findings.
- Normalizer now enriches envelope `Edges` with `EntityRefs` metadata and unions related edge refs into finding `EntityRefs`.
- Added fixture-backed normalizer assertions and wrapper assertions for all new fields.
- Updated `README.md` and `CHANGELOG.md` for the user-visible ETL upgrade.

## Validation

- `Invoke-Pester -Path .\tests\wrappers\Invoke-IdentityGraphExpansion.Tests.ps1,.\tests\normalizers\Normalize-IdentityGraphExpansion.Tests.ps1 -CI`
- `Invoke-Pester -Path .\tests -CI`
