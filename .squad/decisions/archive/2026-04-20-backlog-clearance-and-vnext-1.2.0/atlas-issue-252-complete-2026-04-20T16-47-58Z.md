# Atlas - Issue #252 complete: PERMISSIONS.md split

- **Date (UTC):** 2026-04-20T16:47:58Z
- **Agent:** Atlas
- **Issue:** [#252](https://github.com/martinopedal/azure-analyzer/issues/252) - "docs: PERMISSIONS.md is 867 lines and unreadable. Split per-tool detail to its own page."
- **PR:** [#257](https://github.com/martinopedal/azure-analyzer/pull/257)
- **Merge SHA:** `7b34e719dcf09502d5c22660d5a020efa9ac78a5`
- **Decision status:** Implemented and merged.

## Decision

**Hybrid approach: per-tool prose hand-extracted, INDEX manifest-driven.**

Pure manifest-driven generation was rejected because the existing PERMISSIONS.md content includes rich tool-specific narrative (required scopes, sample CLI commands, "what it does / what it does NOT do" prose blocks, troubleshooting recipes) that does not encode cleanly as JSON without losing significant detail. Encoding all of that as manifest fields would also bloat `tools/tool-manifest.json` well beyond its current scope.

Pure hand-written split was also rejected because the index alone (one entry per tool, grouped by provider) is naturally manifest-driven and would otherwise drift the moment a new tool is added.

The hybrid keeps `tool-manifest.json` as the single source of truth for *what tools exist* (used by the generator + a CI freshness gate) while letting human-curated prose live in dedicated per-tool pages.

## Result

- `PERMISSIONS.md`: **867 -> 116 lines** (-87%). Now contains: core principle, permission domains overview, manifest-driven per-tool index between BEGIN/END markers, least-privilege summary, see-also, maintenance instructions.
- **27 per-tool pages** under `docs/consumer/permissions/<tool>.md` (26 enabled tools + the disabled `copilot-triage` opt-in).
- **5 cross-cutting framework pages** in the same folder:
  - `_summary.md` (cross-tool matrix + permission tier model + what-we-do-not-need)
  - `_continuous-control.md` (#165 OIDC + Function MI + DCR sink)
  - `_multi-tenant.md` (#163 fan-out)
  - `_management-group.md` (recursion + scope behaviour)
  - `_troubleshooting.md` (auth recipes)
- Folder `README.md` introduces the layout.
- `scripts/Generate-PermissionsIndex.ps1`: rewrites the INDEX section between `<!-- BEGIN INDEX -->` / `<!-- END INDEX -->` markers, groups by provider (azure / microsoft365 / graph / github / ado / cli), verifies a per-tool page exists for every enabled tool. Idempotent. `-CheckOnly` for CI.
- `tests/scripts/Generate-PermissionsIndex.Tests.ps1`: 11 Pester tests (markers present, per-tool pages exist, every page starts with the standard H1 contract, idempotent regeneration, `-CheckOnly` clean on the committed tree, every enabled tool appears in generated output, framework pages exist).
- `permissions-pages-fresh` CI gate added to `.github/workflows/docs-check.yml`, mirroring the `tool-catalog-fresh` pattern.
- Stale deep-link anchors patched in `azure-function/README.md` and `docs/consumer/continuous-control.md` (both pointed at `#continuous-control-function-app-165`, now point at `_continuous-control.md`).
- `scripts/Generate-ToolCatalog.ps1` "tier breakdown" link rerouted from PERMISSIONS.md to `docs/contributor/ARCHITECTURE.md#permission-tiers-tier-06` (PERMISSIONS.md no longer documents the tier table inline; `_summary.md` carries the link forward).
- Tool catalog regenerated.
- Em-dash sweep clean over the changeset.

## Validation

- Pester: **1208 passed, 0 failed, 5 skipped** (preserves baseline + 11 new tests).
- All 14 PR checks green: `Analyze (actions)`, `rubberduck-gate`, `Permissions pages fresh`, `Tool catalog fresh`, all three `CI/Test` matrix legs, etc.
- One rebase against main was required mid-flight (PR #249 + PR #256 landed during the work); CHANGELOG conflict was the only resolution.

## Cross-references

- `tools/tool-manifest.json` remains the single source of truth for tool registration.
- `scripts/Generate-ToolCatalog.ps1` (existing) is the model for the new `Generate-PermissionsIndex.ps1`.
- `docs/contributor/ARCHITECTURE.md#permission-tiers-tier-06` is now the canonical home for the permission tier table.
- `docs/consumer/permissions/README.md` is the canonical entry point for "what permissions does $TOOL need".

## Lessons / follow-ups

- The 867 -> 116 line target was "<100" in the original spec; final size is 16 over because the manifest-driven index for 26 tools across 6 provider buckets needs ~50 lines on top of the required summary content. Acceptable per maintainer brief.
- A handful of `.squad/`, `.copilot/`, README, and module references continue to point at root `PERMISSIONS.md`. All remain valid because the file still exists and still carries the summary + index.
- Future work: if a per-tool page itself grows past ~200 lines, consider splitting it the same way (sub-pages under `docs/consumer/permissions/<tool>/`). Not needed today; largest current page is well under that.
