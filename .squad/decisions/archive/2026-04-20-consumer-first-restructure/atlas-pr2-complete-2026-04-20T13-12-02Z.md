### 2026-04-20T13-12-02Z: PR-2 (consumer-first README rewrite) - COMPLETE

**By:** Atlas (claude-sonnet-4.5)
**PR:** [#246](https://github.com/martinopedal/azure-analyzer/pull/246)
**Merge SHA:** `e2d42d7ec037f65a1ac40e2a35169912eeacfe4b`
**Branch:** `docs/readme-consumer-first` (deleted post-merge)
**Stream:** doc-restructure consolidated plan, PR-2 of 5

**Status:** MERGED (squash, admin) at 2026-04-20T13:11:47Z. All 9 required checks green on first try (`Analyze (actions)`, `CodeQL`, `Documentation update check`, `CI/Test` x3 OS, `Verify install manifest`, `Generate SBOM (dry run)`, `advisory-gate`). No iteration loop required.

## What shipped

- Root `README.md` rewritten from 660 lines to **126 lines** (target was `<200`).
- First scroll: badges + one-line value prop + `Install` block + 3 quickstart scenarios.
- Canonical install: `Import-Module .\AzureAnalyzer.psd1; Invoke-AzureAnalyzer`.
- Forward-compatible `Install-Module AzureAnalyzer` claim with the user-approved `# coming in vNEXT once published to PSGallery` footnote (PR-4 #244 already made the manifest publish-ready).
- Cloud-first ordering preserved: scenario 2 leads with `-Repository "github.com/<org>/<repo>"` HTTPS form; `-RepoPath` is mentioned only as a fallback.
- All in-README advanced material (parameter ref, scoped-runs, incremental, install-config, schema, tools catalog, scenarios) routed through the `docs/consumer/README.md` index page (which PR-1 #243 created). PR-3 will fill in the individual extracted pages, at which point Atlas/owner can deep-link them from the README in a follow-up.
- Direct links to existing docs only: `docs/consumer/continuous-control.md`, `docs/consumer/sinks/log-analytics.md`, `docs/consumer/ai-triage.md`, `docs/consumer/gitleaks-pattern-tuning.md`, `docs/contributor/README.md`, `docs/contributor/ARCHITECTURE.md`, `docs/contributor/adding-a-tool.md`, plus root `LICENSE`, `SECURITY.md`, `CONTRIBUTING.md`, `PERMISSIONS.md`, `THIRD_PARTY_NOTICES.md`. Every relative link verified to resolve against the post-PR-1 tree.
- `CHANGELOG.md`: single line under `## [Unreleased]` -> `### Changed` block: `docs: rewrite README to consumer-first quickstart layout (PR-2 of 5)`.

## 3 quickstart scenarios chosen

1. **Run a full Azure assessment for a subscription** - canonical `Connect-AzAccount` + `Invoke-AzureAnalyzer -SubscriptionId` flow. Names the in-scope tools (azqr, PSRule, AzGovViz, ALZ, WARA, Azure Cost, FinOps, Defender).
2. **Scan a remote GitHub repository for CI/CD and secret hygiene** - showcases cloud-first via `-Repository` URL form routed through `RemoteClone.ps1` (HTTPS-only, host allow-list, token scrub). `-RepoPath` is the labeled fallback.
3. **Generate an HTML report from an existing run** - `New-HtmlReport` / `New-MdReport` re-render path from `results.json`; teaches the report features (Summary tab, heatmap, filter bar, CSV export).

## Gates verified

- Em-dash gate: `rg -- "-" README.md` returns nothing on the new file (existing CHANGELOG history em dashes were not touched; only the new line I added is em-dash-free).
- Link gate: every relative target verified with `Test-Path`. No links to PR-3 stub pages that do not yet exist.
- Co-author trailer: present on commit `11d344d`.
- Linear history: single squash-merge.
- Pester: not run (README rewrite + 1-line CHANGELOG edit do not touch any code; no test references README structure - confirmed via `rg README\.md tests/`).

## Stream status after this PR

- PR-1 (#243): MERGED - foundation paths + stubs + indexes
- PR-4 (#244): MERGED - module manifest hygiene + psm1 root-path fix
- **PR-2 (#246): MERGED <- this** - consumer-first README rewrite
- PR-3: NEXT - extracted advanced consumer pages (`scenarios.md`, `reports.md`, `tools.md`, `schema.md`, `install-config.md`, `parameters.md`, `scoped-runs.md`, `incremental.md`). Once those land, the README's "More scenarios" + "What you get" pointers can be deep-linked to specific pages in a small follow-up.
- PR-5: LAST - cleanup + CHANGELOG roll-up

## Worktree cleanup

- `C:\git\worktrees\readme-rewrite` removed.
- Local branch `docs/readme-consumer-first` deleted.
- `origin/main` fast-forwarded `56b4ad0..e2d42d7` locally.
