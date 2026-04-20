# Squad Orchestration Log

Stream-level rollups. One entry per major squad stream after closeout.

---

## Consumer-first documentation restructure (2026-04-20)

**Stream goal:** Pull module *consumption* to the front of the repo and push *contribution* to the back. Replace the 660-line README with a <200-line consumer-first quickstart, extract advanced docs into `docs/consumer/` and `docs/contributor/`, fix the `AzureAnalyzer.psm1` root-path bug, populate `PrivateData.PSData` so the manifest is PSGallery-publish-ready, and close the stream with a clean CHANGELOG roll-up.

**Master plan:** `.squad/decisions/archive/2026-04-20-consumer-first-restructure/coordinator-restructure-consolidated-plan-2026-04-20T12-30-00Z.md` (post 3-of-3 rubberduck APPROVE-WITH-CHANGES).

### PRs shipped (5 of 5, all squash-merged via admin)

| # | PR | Owner | Branch | Merge SHA |
|---|----|-------|--------|-----------|
| PR-1 | [#243](https://github.com/martinopedal/azure-analyzer/pull/243) | Atlas | `docs/restructure-foundation` | `ed6041d07068c990f5fa0dded25f39be5d836870` |
| PR-4 | [#244](https://github.com/martinopedal/azure-analyzer/pull/244) | Forge | `chore/module-consumption-integrity` | `56b4ad0b290a2a737ba37dd3e13b28f5e986ed3a` |
| PR-2 | [#246](https://github.com/martinopedal/azure-analyzer/pull/246) | Atlas | `docs/readme-consumer-first` | `e2d42d7ec037f65a1ac40e2a35169912eeacfe4b` |
| PR-3 | [#247](https://github.com/martinopedal/azure-analyzer/pull/247) | Atlas | `docs/extract-advanced` | `be665ea63ab1163ef77596347c2ba719b32a68ed` |
| PR-5 | [#253](https://github.com/martinopedal/azure-analyzer/pull/253) | Sentinel | `chore/restructure-cleanup` | `3e2f0cdf505a8f5107f09edae56776fca7beb839` |

PR #248 was a side-PR that filed Atlas's PR-3 completion record into `.squad/`. PR-5 therefore landed as #253 rather than the originally-planned #248.

### Follow-up issues filed (4)

- [#249](https://github.com/martinopedal/azure-analyzer/issues/249) - candidate next pickup
- [#250](https://github.com/martinopedal/azure-analyzer/issues/250) - candidate next pickup
- [#251](https://github.com/martinopedal/azure-analyzer/issues/251) - candidate next pickup
- [#252](https://github.com/martinopedal/azure-analyzer/issues/252) - candidate next pickup

All four carry the `squad` label (auto-applied) so Ralph picks them up for dispatch.

### Key decisions adopted in the stream

1. **Manifest-driven tool catalog.** `scripts/Generate-ToolCatalog.ps1` projects `tools/tool-manifest.json` into `docs/consumer/tool-catalog.md` and `docs/contributor/tool-catalog.md`. New CI job `tool-catalog-fresh` (in `.github/workflows/docs-check.yml`) runs `-CheckOnly` on every PR. Adding a manifest entry is the only step needed; generation never breaks.
2. **PSGallery footnote.** README claims `Install-Module AzureAnalyzer` with a `# coming in vNEXT once published to PSGallery` footnote so the consumer surface is forward-compatible. PR-4 made the manifest publish-ready (rotated GUID, populated `PrivateData.PSData` with `Tags`, `ProjectUri`, `LicenseUri`, `ReleaseNotes`); the actual `Publish-Module` invocation is a separate decision out of scope for this stream.
3. **No-meta-refresh stubs.** GitHub markdown sanitizer strips `<meta>` and `<script>`. All 9 redirect stubs are 5-line text-only "Moved to <new path>" pages with one link. Stub retention deadline: removed at v1.1.0 per CHANGELOG entry.
4. **Em-dash gate.** Every PR in the stream MUST sweep new/modified docs for `-` (em dash) and reject if present. Repo rule: no em dashes in any documentation. Codified in `.copilot/copilot-instructions.md` line 221.
5. **Items dropped/deferred.** Item C (`report-template.html` move) deferred to a separate orphan-asset investigation. CONTRIBUTING.md / SECURITY.md / PERMISSIONS.md kept at root because squad automation hardcodes those paths. `Publish-Module` invocation out of scope.

### Models used (frontier-only)

- **Atlas** (PR-1, PR-2, PR-3): `claude-opus-4.7` per charter (one PR-2 spawn ran on `claude-sonnet-4.5` due to a model-availability fallback; output was still gated by the rubberduck trio before merge).
- **Forge** (PR-4): `gpt-5.3-codex`.
- **Sentinel** (PR-5): `gpt-5.4`.
- **Lead** (research + reviewer on every PR): `claude-opus-4.7`.
- **Rubberduck trio** (master plan gate, every PR): `claude-opus-4.7` + `gpt-5.3-codex` + `goldeneye`. 2-of-3 verdict required to land; master plan was 3-of-3 APPROVE-WITH-CHANGES.

### Validation evidence

- Pester baseline preserved and grown across the stream: PR-4 took it from 1076 to 1183 (+import-test family), PR-3 added 14 new generator tests, PR-5 closed at 1197 passed / 0 failed / 5 skipped.
- Required check `Analyze (actions)` green on every PR.
- README went from 660 lines to 126 lines (target was <200) with install + 3-scenario quickstart visible in the first scroll.
- Zero broken internal links to moved docs verified via repo-wide grep before each merge.

### Retro (3 lines)

- **Worked:** atomic PR sequencing (foundation -> module hygiene parallel -> README -> extracted pages -> cleanup) meant every PR landed green on first or near-first push; the rubberduck trio caught the 8-item delta from Lead's research before any code was written.
- **Worked:** the manifest-driven catalog generator turned a 26-row hand-maintained table into a CI-checked projection - new tools now appear in docs automatically.
- **Watch:** Atlas had to fall back to `claude-sonnet-4.5` once mid-stream when `claude-opus-4.7` was unavailable; the frontier fallback chain held but the deliverable still needed the rubberduck gate to catch a missed `Import-Module` example. Codify the fallback handoff in the next charter refresh.

### Closeout

- All 8 stream decision records archived to `.squad/decisions/archive/2026-04-20-consumer-first-restructure/`.
- 4 new skills committed: `consumer-first-module-layout`, `doc-audit-checklist`, `ps-module-publish-readiness`, `repo-link-sweep`.
- 3 agent folders introduced during the stream period (`burke`, `drake`, `sloan`) committed with their first history entries.
- Closeout PR: see `.squad/agents/scribe/history.md` for the merge SHA and PR number.
