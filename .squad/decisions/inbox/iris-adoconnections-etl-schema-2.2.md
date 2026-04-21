# Decision: ado-connections Schema 2.2 ETL shape

- Date: 2026-04-21
- Issue: #367
- Owner: Iris

## Decision

Implement Schema 2.2 additive fields in both ado-connections wrapper and normalizer, with auth-posture semantics:

- Pillar fixed to `Security`
- Impact and Effort derived from auth mechanism and sharing state
- BaselineTags from auth scheme, auth mechanism, and shared vs scoped state
- DeepLinkUrl to ADO service connection settings
- EvidenceUris containing service endpoint REST URI and audit settings URI
- EntityRefs containing org, project, and service connection references
- ToolVersion fixed to `ado-rest-api-7.1`

Canonical entity identity in normalized rows is `org/project/connectionId` to keep EntityStore dedup deterministic.

## Consequences

- No new permission scope is required
- Existing v1 wrapper envelope remains intact
- Schema 2.2 fields flow end to end into findings and entity rollups
