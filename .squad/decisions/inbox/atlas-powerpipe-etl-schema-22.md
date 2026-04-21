# atlas-powerpipe-etl-schema-22

- Issue: #304
- Scope: Add Powerpipe wrapper and normalizer with Schema 2.2 fields.
- Decision:
  - Implement `Invoke-Powerpipe.ps1` with graceful skip when CLI is missing.
  - Implement `Normalize-Powerpipe.ps1` to emit Frameworks, Pillar, Impact, Effort, DeepLinkUrl, RemediationSnippets, EvidenceUris, BaselineTags, Mitre fields, EntityRefs, and ToolVersion.
  - Register `powerpipe` in `tools/tool-manifest.json` and update docs and tests in the same PR.
