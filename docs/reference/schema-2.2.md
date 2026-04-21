# Schema 2.2 Specification

**Status**: In development

Full Schema 2.2 FindingRow specification coming soon.

See [etl-pipeline.md](etl-pipeline.md) for current ETL flow and field descriptions.

## Quick Reference

Schema 2.2 extends Schema 2.0 with 13 new optional fields:

- `Frameworks` — Array of compliance frameworks (e.g., "nist-800-53", "cis-controls-v8")
- `Pillar` — Well-Architected Framework pillar (Security, Reliability, Performance, Cost, OperationalExcellence)
- `Impact` — Severity-based prioritization score (1-10)
- `Effort` — Remediation complexity score (1-10)
- `DeepLinkUrl` — Direct link to resource/entity in Azure Portal or Entra admin center
- `RemediationSnippets` — Code/config samples for fix (PowerShell, Azure CLI, Bicep, Terraform)
- `EvidenceUris` — Supporting evidence links (ARG query results, API responses, screenshots)
- `BaselineTags` — CIS/STIG/NIST baseline identifiers
- `MitreTactics` — MITRE ATT&CK Tactic IDs (e.g., "TA0001")
- `MitreTechniques` — MITRE ATT&CK Technique IDs (e.g., "T1078")
- `EntityType` — Canonical entity type (AzureResource, Subscription, Tenant, User, etc.)
- `EntityRefs` — Linked entity IDs (for cross-finding correlation)
- `ToolVersion` — Tool version metadata for reproducibility

See `modules/shared/Schema.ps1` for implementation.
