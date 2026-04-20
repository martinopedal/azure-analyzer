# PR-3 Complete: Advanced Docs Extraction + Manifest-Driven Tool Catalog

**Author:** Atlas (docs/structure)
**PR:** #247
**Merge SHA:** `be665ea63ab1163ef77596347c2ba719b32a68ed`
**Merged:** 2026-04-20T13:36:31Z
**Master plan items shipped:** G, H, I, J, K

## Summary

Third of five PRs in the consumer-first restructure. Builds the manifest-driven
tool catalog generator, extracts operator content into `docs/contributor/`,
sweeps stale doc paths, and updates index pages. README.md untouched (PR-2 owned).

## Files created

- `scripts/Generate-ToolCatalog.ps1` (362 lines) - manifest-driven catalog generator
- `tests/scripts/Generate-ToolCatalog.Tests.ps1` (14 Pester tests, all green)
- `docs/consumer/tool-catalog.md` (generated, 27 tools, scope reference, disabled section)
- `docs/contributor/tool-catalog.md` (generated, full manifest projection)
- `docs/contributor/operations.md` (operator runbook: shared infra, security invariants, multi-tenant fan-out)
- `docs/contributor/troubleshooting.md` (tool failures, throttling, sanitization, Pester drops, stale catalog)

## Files modified

- `.github/workflows/docs-check.yml`: added `tool-catalog-fresh` job (runs `-CheckOnly`), fixed 2 em-dashes
- `CHANGELOG.md`: appended `### Added` line under `[Unreleased]`
- `CONTRIBUTING.md`: 1 stale-path fix
- `PERMISSIONS.md`: 2 stale-path fixes
- `docs/consumer/README.md`: linked tool-catalog.md
- `docs/contributor/README.md`: linked tool-catalog.md, operations.md, troubleshooting.md

## Generator design

`scripts/Generate-ToolCatalog.ps1` reads `tools/tool-manifest.json` and emits
two markdown projections in stable LF/UTF-8-no-BOM format:

- **Consumer catalog**: alphabetical table of enabled tools with scope, provider,
  human-friendly blurb, and consumer-doc deep links. Plus a scope reference table
  and a disabled-tools appendix.
- **Contributor catalog**: registration matrix (name, scope, provider, install kind,
  enabled flag), invocation table, install + upstream URL table.

Both files carry a `<!-- GENERATED FROM tools/tool-manifest.json -->` header.
Adding a new manifest entry is the only step needed - generation never breaks
because per-tool overrides (`$consumerDocLinks`, `$consumerBlurb`) have safe defaults.

## CI gate

The new `tool-catalog-fresh` job runs `pwsh -File scripts/Generate-ToolCatalog.ps1 -CheckOnly`
on every PR. If a manifest change isn't accompanied by regenerated catalog files,
CI fails with a clear "Run: pwsh -File scripts/Generate-ToolCatalog.ps1" message.

## Item H rationale (no-op)

Master plan explicitly kept PERMISSIONS.md (45 KB), CHANGELOG.md, CONTRIBUTING.md,
and SECURITY.md at the repo root because squad automation hardcodes these paths.
Documented as no-op in the PR body. No file moves performed.

## Iterate-until-green war story

First push to PR #247: ubuntu and windows Test jobs failed in
`tests/shared/Get-CopilotReviewFindings.Tests.ps1`. Initial diagnosis was
"pre-existing CI flake" because tests passed in isolation locally and on main.

Real root cause (caught on careful re-read of failing log):
the `CheckOnly fails when stale` test in my new test file invokes
`Generate-ToolCatalog.ps1 -CheckOnly` against synthetic stale fixtures.
The script exits 1, leaving `$LASTEXITCODE = 1` in the Pester runspace.
Subsequent test files (alphabetically `tests/scripts/...` runs before
`tests/shared/...`) then run `Get-CopilotReviewFindings`, which calls
`Resolve-PRReviewThreads.ps1` line 74-78: it samples `$LASTEXITCODE`
after the mocked `gh` function returns valid JSON and throws
`gh api graphql failed: ...` because the leaked exit code is non-zero.

Fix (1 file, 5 lines): reset `$global:LASTEXITCODE = 0` in the failing
test's `finally` block AND in a new top-level `AfterAll`. After fix
push: all 14 checks green, including `Test (ubuntu-latest)`,
`Test (windows-latest)`, `Test (macos-latest)`, and the new
`Tool catalog fresh`.

Lesson: when a test invokes a script that exits non-zero (even via
`-Whatever | Out-Null`), it MUST reset `$LASTEXITCODE` or every
subsequent test that touches `$LASTEXITCODE` becomes a victim.

## Follow-ups (not blocking, for next docs PR)

1. **`.copilot/skills/architectural-proposals/SKILL.md`** has 19 pre-existing
   em-dashes and references the old `docs/proposals/` path (now at
   `docs/contributor/proposals/`). Should be cleaned up in a focused docs PR
   to avoid bloating an unrelated change.
2. **README.md pruning**: now that `operations.md` and `troubleshooting.md`
   exist as proper operator references, PR-5 (or a follow-up to PR-2) could
   prune any duplicated operator content from README and link to the new pages.
3. **`.squad/templates/`** files are templates for OTHER repos - intentionally
   left untouched.

## Squad protocol checklist

- [x] Branch protection respected (signed commits not required, linear history kept)
- [x] Co-author trailer on commit
- [x] All required checks (`Analyze (actions)`) green
- [x] All advisory checks green (Test x3, Tool catalog fresh, advisory-gate, etc.)
- [x] Em-dash gate clean on diff
- [x] Worktree removed, local branch deleted
- [x] Completion record filed (this file)
