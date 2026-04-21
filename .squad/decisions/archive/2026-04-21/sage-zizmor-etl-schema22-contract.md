# Sage decision: zizmor Schema 2.2 ETL contract

- Date: 2026-04-21
- Issue: #372
- Scope: `Invoke-Zizmor.ps1`, `Normalize-Zizmor.ps1`, zizmor fixtures and tests

## Decisions

1. Wrapper emits Schema 2.2 precursor metadata for each finding: `RuleId`, `Pillar`, `Impact`, `Effort`, `DeepLinkUrl`, `RemediationSnippets`, `EvidenceUris`, `BaselineTags`, `MitreTechniques`, `EntityRefs`, `ToolVersion`.
2. `DeepLinkUrl` resolves to `https://docs.zizmor.sh/audits/#<rule-id>` when rule id exists, with blob evidence URL fallback.
3. `EvidenceUris` use GitHub blob links with commit SHA and line anchors when location metadata is present.
4. Workflow entities normalize to `owner/repo/.github/workflows/<file>.yml` for dedup across multi-rule findings.
5. EntityStore framework merge path now uses `Merge-FrameworksUnion` to align with Schema 2.2 union helpers.

## Validation plan

- Run `Invoke-Pester -Path .\tests -CI` in the worktree.
- Merge only after local tests and required CI checks are green.
