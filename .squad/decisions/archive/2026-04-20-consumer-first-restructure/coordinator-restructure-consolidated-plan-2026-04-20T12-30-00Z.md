### 2026-04-20T12-30-00Z: Consumer-first restructure - consolidated plan (post 3-of-3 rubberduck)

**By:** Squad Coordinator on behalf of martinopedal
**Gating directive:** coordinator-doc-restructure-consumer-first-2026-04-20T13-35-46Z.md
**Inputs:** lead-restructure-research-2026-04-20T12-17-33Z.md, sage-consumer-module-patterns-2026-04-20T12-17-17Z.md
**Rubberduck verdict:** Opus 4.7 + GPT-5.3-codex + Goldeneye = APPROVE-WITH-CHANGES (3-of-3)

---

## Changes adopted from the trio

1. **Drop item C** (report-template.html move). 3-of-3 found NO references to it in any .ps1/.psm1/.psd1. File is orphaned or generated. Demote to a separate "investigate orphan" issue, do not touch in this stream.
2. **Bake docs-check.yml patch into the move PR.** `.github/workflows/docs-check.yml` lines 50/71/72 hardcode root doc filenames including AI_GOVERNANCE.md. Moving AI_GOVERNANCE.md without patching this workflow breaks the check.
3. **Stubs are text-only.** GitHub markdown sanitizer strips `<meta>` and `<script>`. The "meta-refresh" idea is fiction. Stubs are 5-line "Moved to <new path>" with a single link. Time-box stub retention to one minor version, tracked in a follow-up issue.
4. **PSGallery manifest hygiene ships in this stream.** README will document `Install-Module` as the canonical path; the manifest must back it. Add a dedicated PR for `PrivateData.PSData` + real GUID + Tags + ProjectUri + LicenseUri.
5. **README rewrite lands EARLY (PR-2), not last.** The directive is about first impression; shuffling files first without a new README delays the user-visible value.
6. **Keep CONTRIBUTING.md, SECURITY.md, PERMISSIONS.md at root.** Squad automation, .squad/ files, and .copilot/copilot-instructions.md hardcode these paths. The visual-tidiness benefit at root is marginal; the breakage cost is real.
7. **First-class link sweep.** Grep `.squad/`, `.copilot/`, `.github/`, root `*.md` and patch every reference to moved paths IN the move PR, not as cleanup.
8. **Add new item R: AzureAnalyzer.psm1 root path bug.** Codex flagged: `Split-Path -Parent $PSScriptRoot` resolves OUTSIDE the module folder, which is the opposite of "easy module consumption." Fix + add Pester test that `Import-Module .\AzureAnalyzer.psd1` exposes the exported functions.
9. **Per-PR model assignments (frontier-only).** Atlas/Sage/Forge/Sentinel spawns name a model from {opus-4.7, opus-4.6-1m, gpt-5.4, gpt-5.3-codex, goldeneye}.
10. **Named fallback author for README PR (reviewer lockout).** If Lead rejects Atlas's README rewrite, Sage takes the revision; Forge is the secondary fallback.
11. **Per-PR success metric** (one quantifiable outcome).
12. **Em-dash merge gate.** Every PR in this stream MUST grep new/modified docs for `-` and reject if present. Repo rule: no em dashes in documentation.

---

## Final PR plan (5 PRs, gated, atomic)

### PR-1: Foundation - paths and stubs
- **Branch:** `docs/restructure-foundation`
- **Owner:** Atlas (claude-opus-4.7), reviewed by Lead (claude-opus-4.7)
- **Items:** A (move 8 docs files into `docs/consumer/` and `docs/contributor/`), B (text-only redirect stubs at every old path), E (move AI_GOVERNANCE.md to `docs/contributor/ai-governance.md`), L (add `docs/consumer/README.md` and `docs/contributor/README.md` indexes), N (sweep `.squad/`, `.copilot/`, `.github/`, root *.md for references to moved paths and patch every hit), patch `.github/workflows/docs-check.yml` lines 50/71/72.
- **Success metric:** zero broken internal links to moved docs. Verify via `gh pr checks` green and a final grep of the repo for old paths returning only intentional stubs.
- **Em-dash gate:** mandatory.

### PR-2: Consumer-first README rewrite
- **Branch:** `docs/readme-consumer-first`
- **Owner:** Atlas (claude-opus-4.7) drafts, Lead (claude-opus-4.7) reviews. **Reviewer-lockout fallback:** Sage (claude-opus-4.7); secondary Forge (gpt-5.3-codex).
- **Items:** F (rewrite README to <=200 lines, install + 3-scenario quickstart in first scroll, advanced as link index), M (document `Import-Module .\AzureAnalyzer.psd1; Invoke-AzureAnalyzer` as canonical module-consumption path), keep cloud-first ordering (remote URL targeting first, `-RepoPath` clearly labeled as fallback).
- **Success metric:** README under 200 lines AND install+quickstart visible within first 60 lines AND `Import-Module` example present.
- **Em-dash gate:** mandatory.

### PR-3: Extracted advanced docs
- **Branch:** `docs/extract-advanced`
- **Owner:** Atlas (claude-opus-4.7), reviewed by Lead.
- **Items:** G (`docs/consumer/scenarios.md` for 5 advanced scenarios), H (`docs/consumer/reports.md`), I (`docs/consumer/tools.md` for the 26-tool catalog - Sage advises whether this should be manifest-driven), J (`docs/consumer/schema.md`), K (`docs/consumer/{install-config, parameters, scoped-runs, incremental}.md`).
- **Success metric:** README contains no inline 26-tool table, no inline schema reference, no inline scenario walls. All replaced by link index.
- **Em-dash gate:** mandatory.

### PR-4: Module integrity + manifest hygiene
- **Branch:** `chore/module-consumption-integrity`
- **Owner:** Forge (gpt-5.3-codex), reviewed by Lead.
- **Items:**
  - **Item R (NEW):** Fix `AzureAnalyzer.psm1` root-path resolution. `Split-Path -Parent $PSScriptRoot` is wrong - module root IS `$PSScriptRoot`. Add Pester test that `Import-Module .\AzureAnalyzer.psd1` exposes `Invoke-AzureAnalyzer`, `New-HtmlReport`, `New-MdReport`.
  - **Item Q (NEW):** Complete `AzureAnalyzer.psd1` `PrivateData = @{ PSData = @{ ... } }` block: `ProjectUri`, `LicenseUri`, `Tags`, `ReleaseNotes`. Rotate the placeholder GUID with `[guid]::NewGuid()`.
- **Success metric:** Pester baseline green (1076/1076 + new import test) AND `Test-ModuleManifest .\AzureAnalyzer.psd1` returns no errors AND PSData block populated.
- **Em-dash gate:** mandatory (psd1/psm1 docs blocks).

### PR-5: Cleanup + CHANGELOG
- **Branch:** `chore/restructure-cleanup`
- **Owner:** Sentinel (gpt-5.4), reviewed by Lead.
- **Items:** D (`git rm` `pester.log`, `retry.log`, `testResults.xml`; add to `.gitignore`; verify `output*/` in `.gitignore`), P (single CHANGELOG entry announcing the restructure with old->new path map and stub-retention deadline).
- **Success metric:** zero committed logs/test artifacts at root AND CHANGELOG entry present.
- **Em-dash gate:** mandatory.

---

## Items deferred / dropped

- **Item C (`report-template.html` move):** DROPPED. Filed as a separate `chore: investigate orphan asset report-template.html` issue. Resolve before any move.
- **Move CONTRIBUTING.md / SECURITY.md to `.github/`:** DROPPED. Squad automation hardcodes root paths.
- **Move PERMISSIONS.md to `docs/governance/`:** DROPPED. 45 KB tier-1 consumer doc with too many inbound references. Optional follow-up: trim PERMISSIONS.md by extracting per-tool detail to `docs/consumer/permissions/` and keeping a roll-up at root - separate stream, not in scope here.
- **Actually publish to PSGallery:** OUT OF SCOPE. PR-4 makes the manifest publish-ready; the `Publish-Module` invocation is a separate decision.
- **Markdown link-check workflow:** OUT OF SCOPE. Filed as a follow-up issue.

---

## Issue / PR sequencing rules

- PR-1 must merge before PR-2/3 (they need the new dirs to exist).
- PR-2 and PR-3 can run in parallel after PR-1 (different files).
- PR-4 is fully independent of doc PRs (touches psm1/psd1) - can run in parallel from day 1.
- PR-5 must merge LAST (CHANGELOG entry needs final state).
- Every PR runs through iterate-until-green: `gh pr checks <num> --watch`. Required check is `Analyze (actions)`. Loop until green AND merged. No abandoning red PRs.
- Branch protection: signed commits NOT required, 0 reviewers, linear history. Squash-merge.

---

## Open questions for the user (blocking)

1. **PR-2 timing.** Goldeneye argues the README rewrite should land second (right after PR-1 foundation). Lead originally proposed it as PR-4 (after all extracted pages exist). Trade-off: early README rewrite means temporarily-broken in-README links until PR-3 lands; late rewrite delays user-visible value. **Recommendation: early (PR-2)** with placeholder links to extracted pages that PR-3 fills in. Confirm or override.
2. **Item I tool catalog: handwritten vs manifest-generated?** `tools/tool-manifest.json` is single source of truth. The 26-tool table could be generated at build time. Recommendation: keep handwritten in PR-3, file a follow-up issue for generation. Confirm.
3. **PSGallery publish target.** PR-4 makes the manifest publish-ready. Should the README §Install actually claim `Install-Module AzureAnalyzer` (with a footnote "publishing soon"), or wait until publish lands? Recommendation: claim it with a "(coming in vNEXT)" footnote so the README is forward-compatible. Confirm.
