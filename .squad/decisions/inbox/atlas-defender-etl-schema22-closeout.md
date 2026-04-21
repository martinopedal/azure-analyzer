# Atlas decision drop: Defender ETL Schema 2.2 closeout

Date: 2026-04-21
Issue: #302

## Decision

Implement Defender for Cloud Schema 2.2 plumbing in wrapper + normalizer using `New-FindingRow` fields only for renderable schema attributes.

## Implemented mapping

- Wrapper now captures and emits:
  - `ToolVersion`
  - `Pillar` (`Security`)
  - `Frameworks` (MCSB, ISO27001, PCI, CIS, NIST, SOC2 when found in Defender payloads)
  - `DeepLinkUrl`
  - `EvidenceUris`
  - `MitreTactics`, `MitreTechniques` from Defender alerts
- Wrapper adds Defender alerts endpoint fan-out (`Microsoft.Security/alerts`) and skips dismissed/resolved alerts.
- Normalizer passes Schema 2.2 fields through `New-FindingRow`.
- Removed Defender normalizer Add-Member extras for schema-owned fields.

## Test coverage

- Updated defender fixture with assessment + alert records carrying schema fields.
- Extended normalizer tests for Schema 2.2 pass-through and MITRE assertions.
- Added wrapper success-path tests with mocked secure score, assessments, and alerts payloads.
