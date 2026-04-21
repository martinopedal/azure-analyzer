# extra-376-terraformiac

## Context
- Issue: #376
- Scope: terraform-iac Schema 2.2 ETL closure

## Decisions
- Deferred `IaCFile` as a first-class `EntityType` to a dedicated follow-up issue and kept this release on `EntityType=Repository`.
- Terraform IaC findings now emit Schema 2.2 fields from wrapper to normalizer: `Frameworks`, `Pillar`, `DeepLinkUrl`, `RemediationSnippets`, `EvidenceUris`, `BaselineTags`, `EntityRefs`, `ToolVersion`.
- Severity mapping now explicitly covers trivy `UNKNOWN -> Info`.
- Entity IDs now use `iac:terraform:{relative-path}#{resource_address}` when no ARM resource id resolves, enabling stable entity dedup on `Platform|EntityType|EntityId`.
- Tool version probes include terraform and trivy, with tfsec and checkov when available.

## Validation
- Targeted suites green:
  - `tests/normalizers/Normalize-IaCTerraform.Tests.ps1`
  - `tests/shared/IaCAdapters.Tests.ps1`
  - `tests/shared/Schema.Tests.ps1`
