# Sentinel decision - Maester Schema 2.2 ETL

- Date: 2026-04-21
- Issue: #305
- Scope: `Invoke-Maester.ps1`, `Normalize-Maester.ps1`, Maester fixtures and tests

Decision:
- Preserve one-test-to-one-finding shape and enrich each finding with Schema 2.2 optional fields.
- Derive `Frameworks` and `BaselineTags` from Maester tags for CIS Microsoft 365, NIST 800-53, and EIDSCA.
- Pass MITRE tactics and techniques from tags when present.
- Set `Pillar` to `Security`.
- Build `DeepLinkUrl` as `https://maester.dev/docs/tests/{TestId}`.
- Emit `EvidenceUris` from test source and Learn docs.
- Emit `RemediationSnippets` from "How to fix" markdown code blocks, fallback to text.
- Emit `EntityRefs` with tenant ID and service principal IDs from test scope.
- Emit `ToolVersion` from installed Maester module version.
- Keep tenant-scoped normalization (`EntityType=Tenant`, `Platform=Entra`) and canonicalize entity refs.
