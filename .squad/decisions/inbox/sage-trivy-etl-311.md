# Decision: Trivy Schema 2.2 ETL for issue #311

Date: 2026-04-21  
Owner: Sage

## Context

Issue #311 requires Trivy wrapper and normalizer support for the locked Schema 2.2 additive fields.

## Decision

Implement Schema 2.2 enrichment in `Invoke-Trivy.ps1` and pass-through in `Normalize-Trivy.ps1` with deterministic image digest entity IDs:

- Wrapper emits `Pillar`, `Impact`, `Effort`, `DeepLinkUrl`, `Frameworks`, `RemediationSnippets`, `EvidenceUris`, `BaselineTags`, `ScoreDelta`, `EntityRefs`, `RuleId`, and `ToolVersion`.
- Wrapper parses both `Vulnerabilities` and `Misconfigurations` and keeps one finding per CVE.
- Normalizer preserves all 2.2 fields through `New-FindingRow` and maps digest resource IDs to `trivy/image/sha256:...`.
- Tests and fixtures are updated to assert the new ETL contract.

## Rationale

This keeps Trivy aligned with Schema 2.2 and the entity dedup contract while preserving existing v1 envelope behavior and non-throwing wrapper semantics.

