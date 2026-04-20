# Sage Research Brief - Consumer-First Repo Layouts for PowerShell Modules

- **Author:** Sage (Research & Discovery)
- **Date:** 2026-04-20 (UTC)
- **Requested by:** martinopedal via Coordinator (`coordinator-doc-restructure-consumer-first-2026-04-20T13-35-46Z.md`)
- **Scope:** Pre-design research for the doc + repo restructure that pulls *consumption* to the front and pushes *contribution* to the back. Not a design doc - a pattern catalog with citations.

> All claims below are URL-cited. Access date: 2026-04-20. Where I quote a project's structure, I link the repo root or the specific file in `main`.

---

## 1. Reference repos - six in the wild

I picked repos that (a) are widely consumed via PSGallery, (b) bundle/orchestrate other tools (closer to azure-analyzer's shape than a single-purpose cmdlet library), and (c) have visible doc-vs-code separation.

### 1.1 PSRule for Azure - `Azure/PSRule.Rules.Azure`
- URL: https://github.com/microsoft/PSRule.Rules.Azure (redirects to `Azure/PSRule.Rules.Azure`)
- Root README sections, in order: tagline → **Features** → **Project objectives** → **Support** → **Getting the modules** (PSGallery + install link) → **Getting started** (pre-flight / in-flight) → **Using with GitHub Actions** → scenarios → links to docs site. Source: README rendered at the URL above.
- Consumer vs contributor split: **all narrative docs live on a separate docs site** (`https://azure.github.io/PSRule.Rules.Azure/`) generated from the repo. The README is a landing pad that pushes consumers off-repo into the docs site after the install snippet. CONTRIBUTING is referenced from the docs site's "license-contributing" page, not surfaced in the README.
- Install lives in the README's third visible section. Contributor onboarding is one click away (docs site → "Contributing").

### 1.2 Pester - `pester/Pester`
- URL: https://github.com/pester/Pester
- Root README sections: sponsor banner → docs site link (`pester.dev/docs/quick-start`) → tagline → **runnable example** → **Installation** → **Signing certificates** → community/contribution call-out. Source: README rendered at the URL.
- Consumer vs contributor split: identical pattern to PSRule - narrative on a separate docs site (`pester.dev`); the README is a single-screen "what is it / how to install / one example" page. Contributor onboarding lives at `https://pester.dev/docs/contributing/introduction`, linked from the README's "looking for contributors" call-out.
- Note: README explicitly tags "good first issue" / "bad first issue" labels for contributors but keeps that *below* the install + example block.

### 1.3 PSReadLine - `PowerShell/PSReadLine`
- URL: https://github.com/PowerShell/PSReadLine
- Root README sections: badge → feature bullets → external write-ups → **Installation and Upgrading** → **Usage** → custom keybinding examples → roadmap. Source: README rendered at the URL.
- Consumer-first: install + usage dominate the first scroll. Contributor info is in a separate `CONTRIBUTING.md` at root (GitHub auto-detects it; not surfaced in README body).

### 1.4 ImportExcel - `dfinke/ImportExcel`
- URL: https://github.com/dfinke/ImportExcel
- Root README: logo → donate banner → **Overview** → **Examples link** → **Basic Usage** → **Installation** (`Install-Module -Name ImportExcel`) → many runnable snippets → resources/videos. Source: README at the URL.
- Consumer-first: examples *outrank* installation in the table of contents because the project is example-driven. Contributor docs are minimal and live in a root `CONTRIBUTING`-style file plus the wiki.

### 1.5 Microsoft Graph PowerShell SDK - `microsoftgraph/msgraph-sdk-powershell`
- URL: https://github.com/microsoftgraph/msgraph-sdk-powershell
- Root README sections: tagline → **API Documentation / SDK Documentation** links → in-page nav (`Modules | Getting Started | API Version | Notes | Troubleshooting | Known Issues | Feedback | License`) → **Modules table** with PSGallery badges → **Getting Started** (Installation → Authentication → first-call examples) → API version → Notes → Troubleshooting. Source: README at the URL.
- Consumer vs contributor split: navigation header has *zero* contributor links. CONTRIBUTING + dev-setup live under `docs/` in the repo and inside `.github/`; not surfaced to consumers. `docs/authentication.md` is referenced from the README - that's a consumer-facing doc and lives in `docs/`.

### 1.6 Azure Verified Modules (Bicep registry) - `Azure/bicep-registry-modules`
- URL: https://github.com/Azure/bicep-registry-modules
- Root README sections: scorecard badge → **Azure Verified Modules** intro → **Available Modules** (link to off-repo index) → **Contributing** (with a clear separation: anyone can file issues; only Microsoft FTEs own modules) → **Data Collection / telemetry**. Source: README at the URL.
- Notable consumer-first move: "Available Modules" is just a link to `aka.ms/AVM/ModuleIndex/Bicep` - the consuming index is *not* in the repo at all, so the repo browse experience stays focused on contributing to module source.
- This is the inverse pattern from azure-analyzer's needs: AVM optimizes the repo for *contributors* because consumption happens via Bicep registry pulls, not GitHub. Useful as a contrast.

### Honourable mention - `PowerShell/SecretManagement`
- URL: https://github.com/PowerShell/SecretManagement
- README is a long technical reference, not consumer-first - included to show the *anti-example* of a Microsoft-owned PS module that buries the install snippet under multiple sections of vault-author guidance. (Source: README at the URL.) Don't copy this layout.

---

## 2. Common patterns - the catalog

Distilling the five consumer-friendly references (PSRule, Pester, PSReadLine, ImportExcel, msgraph-sdk-powershell), a clear pattern emerges:

### 2.1 README skeleton (sections + order)

The dominant order across all five:

1. **One-line tagline** (what it is, in plain language)
2. **Status badges** (build, PSGallery downloads, license)
3. **Feature bullets** *or* a runnable example (project's choice - Pester picks example, PSRule picks features)
4. **Install** - verbatim copy-pasteable `Install-Module …` (or `git clone` for non-gallery modules)
5. **Quick start** - minimal end-to-end scenario, runnable in <2 minutes
6. **Common scenarios** - 2–5 named recipes
7. **Where to read more** - link to docs site, wiki, or `docs/` folder
8. **Support / community** - issues link, discussions link
9. **Contributing** - *one paragraph, links out to CONTRIBUTING.md*
10. **License**

Sources: PSRule README, Pester README, PSReadLine README, ImportExcel README, msgraph-sdk-powershell README (URLs above).

### 2.2 CONTRIBUTING.md placement

GitHub officially recognises `CONTRIBUTING.md` in **three locations**, with this priority for "Contributing" links: `.github/` → repo root → `docs/` (source: GitHub Docs, https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/setting-guidelines-for-repository-contributors).

Implication for consumer-first restructures: you can move `CONTRIBUTING.md` *off* the root and into `.github/CONTRIBUTING.md` and GitHub will still:
- show a "Contributing" tab in the repo overview,
- show a "Contributing" sidebar link,
- link it from new-issue / new-PR pages.

This is the key mechanism that lets you "hide" contributor noise from the root file list without breaking GitHub's affordances.

### 2.3 docs/ subfolder conventions

There is no single convention, but the recurring split across the five references:

| Folder | Audience | Examples in references |
|---|---|---|
| `docs/` (or external site) | Consumer narrative + reference | PSRule (full docs site), Pester (`pester.dev`), msgraph (`docs/authentication.md`) |
| `docs/guides/` or `docs/scenarios/` | Consumer task-oriented walk-throughs | PSRule docs site `scenarios/`, msgraph wiki |
| `docs/reference/` | Auto-generated cmdlet help (`platyPS` output) | msgraph `docs/` per-module reference |
| `docs/contributor/` *or* `docs/dev/` | Contributor narrative (architecture, build, release) | Pester's `docs/contributing/`, msgraph `docs/` design notes |
| `.github/` | Governance + PR/issue templates + (optionally) `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, `CODEOWNERS` | Universal across all references |

### 2.4 Where CHANGELOG / SECURITY / CODE_OF_CONDUCT live

- `CHANGELOG.md` at repo root is the dominant pattern - Pester, PSReadLine, ImportExcel all keep it at root because PSGallery `ReleaseNotes` typically points to it.
- `SECURITY.md` at repo root or `.github/SECURITY.md`. GitHub surfaces it as a "Security policy" tab from either location (source: GitHub Docs community-health files).
- `CODE_OF_CONDUCT.md` at root or `.github/`. Same auto-detection.
- Governance / AI-policy material (azure-analyzer's `AI_GOVERNANCE.md`, `PERMISSIONS.md`, `THIRD_PARTY_NOTICES.md`) is *not* a GitHub-recognised file - it's safe to relocate into `docs/governance/` and link from README. No GitHub UI affordance is lost.

---

## 3. PSGallery + module-consumption specifics

### 3.1 What `PowerShellGet` / `PSResourceGet` actually pulls

When a consumer runs `Install-Module azure-analyzer`, the Gallery serves the package built from the `.psd1` + `.psm1` + everything `RootModule` and `FileList` reference. The Gallery's package page UI is driven *entirely* by the manifest (source: Microsoft Learn, https://learn.microsoft.com/en-us/powershell/gallery/concepts/package-manifest-affecting-ui).

### 3.2 Manifest fields that surface to consumers

Per the same Learn doc, the Gallery page renders these fields directly:

| Field | Where it appears on the Gallery page |
|---|---|
| `Description` | Hero blurb |
| `Author`, `CompanyName`, `Copyright` | Sidebar |
| `PrivateData.PSData.ProjectUri` | "Project Site" link |
| `PrivateData.PSData.LicenseUri` | "License Info" link |
| `PrivateData.PSData.IconUri` | Tile icon |
| `PrivateData.PSData.ReleaseNotes` | "Release notes" tab |
| `PrivateData.PSData.Tags` | Tag chips + search relevance |
| `HelpInfoUri` (manifest root) | Updatable Help target (source: https://learn.microsoft.com/en-us/powershell/scripting/developer/module/how-to-write-a-powershell-module-manifest) |
| `RequiredModules`, `PowerShellVersion`, `CompatiblePSEditions` | Dependency + compatibility chips |

### 3.3 Audit of current `AzureAnalyzer.psd1`

I read `C:\git\azure-analyzer\AzureAnalyzer.psd1`. Findings:

- ✅ `RootModule`, `ModuleVersion`, `GUID`, `Author`, `CompanyName`, `Description`, `PowerShellVersion`, `FunctionsToExport` are populated.
- ❌ **No `PrivateData.PSData` block at all.** That means: no `ProjectUri`, no `LicenseUri`, no `IconUri`, no `ReleaseNotes`, no `Tags`. If we publish to PSGallery as-is, the package page will be a dead-end with no link back to GitHub and no tags for discovery.
- ❌ **No `HelpInfoUri`.** Updatable Help is not wired.
- ❌ `GUID` is a placeholder pattern (`0e0f0e0f-…`) - must be regenerated with `[guid]::NewGuid()` before first publish, or a future genuine GUID will collide.
- ⚠️ `FunctionsToExport` lists only three (`Invoke-AzureAnalyzer`, `New-HtmlReport`, `New-MdReport`) - fine, but `New-ExecDashboard.ps1` is at the repo root and not exported. Decision needed: is it a public consumer surface or an internal script?

**Restructure-relevant action items for the manifest:**
1. Add a `PrivateData = @{ PSData = @{ … } }` block with `ProjectUri = 'https://github.com/martinopedal/azure-analyzer'`, `LicenseUri`, `Tags`, and `ReleaseNotes` pointing at the new location of the consumer-facing release notes (likely `CHANGELOG.md` at root or `docs/release-notes.md`).
2. If the restructure moves `LICENSE` out of the root, **don't** - keep `LICENSE` at root so `LicenseUri = '…/blob/main/LICENSE'` keeps working and so GitHub's "License" sidebar chip still resolves.
3. Set `HelpInfoUri` only if we commit to producing PlatyPS / Updatable Help. Otherwise, leave it out - an empty value is worse than absent.

---

## 4. GitHub repo-browse experience

What appears on `github.com/martinopedal/azure-analyzer` today (snapshot at task start) is a flat list of 19 directories and 17 root files. That's the friction the user is asking to fix.

Mechanisms to *quietly* move noise without breaking discoverability:

- **`.github/` directory** is treated specially by GitHub. Files placed there (`CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, `PULL_REQUEST_TEMPLATE.md`, `ISSUE_TEMPLATE/`, `CODEOWNERS`, `dependabot.yml`, `FUNDING.yml`) are auto-detected and surfaced in the right places (issue-creation flow, PR-creation flow, Security tab, Insights → Community Standards). Source: GitHub Docs community-health files page (URL above).
- **Dotfile dirs** (`.copilot/`, `.squad/`, `.atlas-stash/`) collapse to the bottom of the file list and are visually de-emphasised. They stay searchable by `grep`/`code search` but don't dominate browse.
- **Folder convention `docs/contributor/` or `docs/dev/`** signals to readers: "this is for people changing the code, not using it." Several of the references (Pester, msgraph) follow this.
- **Top-of-README "table of contents" with explicit consumer/contributor split** (msgraph SDK does this - `Getting Started | API Version | Notes | Troubleshooting | Known Issues | Feedback | License`, no contributor link in the nav). This is the single highest-leverage move.

---

## 5. Anti-patterns to avoid

Drawn from common breakage observed on GitHub when repos are restructured (citations are GitHub Docs unless noted):

1. **Moving `CONTRIBUTING.md` to a non-recognised path.** GitHub only auto-detects it in `.github/`, repo root, or `docs/` - anywhere else (e.g. `docs/contributor/CONTRIBUTING.md`) breaks the "Contributing" tab and PR-form link. Source: https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/setting-guidelines-for-repository-contributors.
2. **Moving `LICENSE`.** GitHub's license detector + the "License" sidebar chip require it at root with a recognised filename. Source: same Community-Health-Files docs.
3. **Moving `SECURITY.md` / `CODE_OF_CONDUCT.md` outside `{root, .github/, docs/}`.** Same auto-detection rules.
4. **Breaking inbound links / search SEO.** Existing blog posts, Q&A, internal wikis, and PSGallery `ProjectUri` may deep-link to `README.md#some-section` or `PERMISSIONS.md`. Anchor IDs are derived from heading text - *renaming* a heading silently breaks deep links. Mitigation: when relocating sections, keep a short stub at the old path with a redirect-style note ("Moved to `docs/…`"). For `.md` files specifically, GitHub will not auto-redirect on a rename.
5. **`CODEOWNERS` path coupling.** `CODEOWNERS` patterns are evaluated against the new tree. Any rule like `/CONTRIBUTING.md @owner` silently stops matching after a move. Audit `.github/CODEOWNERS` *as part of* the restructure PR.
6. **PR / issue template path coupling.** `pull_request_template.md` referenced via query string (`?template=…`) breaks if renamed. azure-analyzer currently has `.github/pull_request_template.md` - safe to leave alone.
7. **Tools that hardcode doc paths.** Search the repo for string literals like `'README.md'`, `'PERMISSIONS.md'`, `'docs/'` before moving anything - orchestrators, report generators, and CI workflows often hardcode them. Specifically check `New-HtmlReport.ps1`, `New-MdReport.ps1`, `tools/`, `scripts/`, and any GitHub workflow that publishes docs.
8. **Removing files without committing the replacement.** If `PERMISSIONS.md` is moved into `docs/`, the manifest's `ProjectUri` plus any external bookmarks pointing at `…/blob/main/PERMISSIONS.md` 404. Either keep a stub or redirect via a docs site.
9. **Burying the install snippet below the fold.** Per all five reference repos, the install command must be visible *without scrolling*. Long pre-amble (architecture diagrams, governance disclaimers) before install is the single biggest consumer-friction anti-pattern.
10. **Splitting the README into many short files.** Consumers expect a single landing page. Splitting "what is it / install / quick start" across three files (as some over-engineered repos do) increases friction. Keep the README as the one-page on-ramp; depth lives in `docs/`.

---

## 6. Recommendation for azure-analyzer (one page)

> **If it were me.** Given that azure-analyzer is on a path to PSGallery publication and is currently consumed via `git clone` + `.\Invoke-AzureAnalyzer.ps1`, the restructure should make the *first scroll* of both the GitHub repo and the README answer one question: "How do I run this and read a report?"

**Proposed root layout (post-restructure):**

```
README.md                  # consumer-first, one-page on-ramp
LICENSE                    # do NOT move (GitHub auto-detect)
CHANGELOG.md               # do NOT move (PSGallery ReleaseNotes target)
AzureAnalyzer.psd1         # consumer manifest entry point
AzureAnalyzer.psm1
Invoke-AzureAnalyzer.ps1   # primary consumer CLI
modules/                   # implementation (consumers don't open this)
queries/                   # ARG queries (consumers don't open this)
templates/, samples/       # consumer-facing examples
docs/
  guides/                  # consumer task recipes
  reference/               # cmdlet reference (PlatyPS output if/when added)
  governance/              # AI_GOVERNANCE.md, PERMISSIONS.md, THIRD_PARTY_NOTICES.md
  contributor/             # ARCHITECTURE.md, CONTRIBUTING-TOOLS.md, dev setup
.github/
  CONTRIBUTING.md          # MOVE here from root (GitHub auto-detects)
  SECURITY.md              # MOVE here from root (GitHub auto-detects)
  CODE_OF_CONDUCT.md       # if added later
  pull_request_template.md # leave in place
  CODEOWNERS               # audit paths after move
.copilot/, .squad/, .atlas-stash/   # dotfile dirs - collapse to bottom of file list, untouched
azure-function/, infra/, hooks/, tools/, scripts/, tests/   # untouched
output*/                   # gitignore - don't ship
```

**README skeleton (proposed order):**

1. One-line tagline (already strong - keep, trim the 26-tool inline list to a "covers …" line)
2. Badges (CI, PSGallery downloads once published, license)
3. **Install** - the very next thing. Both `Install-Module azure-analyzer` (post-publish) and the current `git clone` path.
4. **Quick start** - Scenario 1 only (Azure resources). Move scenarios 2–5 into `docs/guides/scenarios.md`.
5. **Reading the report** - 5-line description + screenshot link, deep-link to `docs/guides/report-anatomy.md`.
6. **What it covers** - collapsible/short version of the 26-tool list, with a link to `docs/reference/tools.md`.
7. **Permissions at a glance** - 3-line summary, link to `docs/governance/PERMISSIONS.md`.
8. **Documentation** - section header that links to `docs/guides/`, `docs/reference/`, `docs/governance/`.
9. **Contributing** - single paragraph, links to `.github/CONTRIBUTING.md` and `docs/contributor/`.
10. **License**.

**Manifest changes to ship in the same PR:**

- Add `PrivateData.PSData` with `ProjectUri`, `LicenseUri`, `Tags = @('Azure','Assessment','Compliance','PSRule','azqr','Security','FinOps','ALZ')`, and `ReleaseNotes` pointing at `CHANGELOG.md` (or a Releases-page URL).
- Generate a real `GUID` before first publish.
- Decide on `New-ExecDashboard` export status now, not later.

**One-PR contract (this is the riskiest part):**

- Move files *and* update every internal link in the same commit.
- Grep-audit before push: `'README.md'`, `'PERMISSIONS.md'`, `'AI_GOVERNANCE.md'`, `'THIRD_PARTY_NOTICES.md'`, `'docs/'`, `'CONTRIBUTING.md'`, `'SECURITY.md'` across `**/*.ps1`, `**/*.psm1`, `**/*.yml`, `**/*.md`.
- Update `.github/CODEOWNERS` paths.
- Leave a 1-line stub at each old root-level location pointing to the new path, *for one release cycle*, then remove. This protects external bookmarks and PSGallery's `ProjectUri`.
- Validate with `Test-ModuleManifest .\AzureAnalyzer.psd1` and run the full Pester suite (`Invoke-Pester -Path .\tests -CI` - baseline 842/842 per repo Copilot instructions).

**Out of scope for this brief (hand-offs):**

- Actual PR authoring → Lead routes to the appropriate specialist (likely Forge for the workflow + manifest changes, Sentinel for any report-template path coupling).
- Decision on whether to stand up an off-repo docs site (à la `pester.dev`, `azure.github.io/PSRule.Rules.Azure`). Recommend deferring until v1.x - `docs/` in-repo is sufficient for the current size.

---

## Sources (all accessed 2026-04-20)

- https://github.com/microsoft/PSRule.Rules.Azure (root README)
- https://github.com/pester/Pester (root README)
- https://github.com/PowerShell/PSReadLine (root README)
- https://github.com/dfinke/ImportExcel (root README)
- https://github.com/microsoftgraph/msgraph-sdk-powershell (root README)
- https://github.com/Azure/bicep-registry-modules (root README)
- https://github.com/PowerShell/SecretManagement (root README - anti-example)
- https://learn.microsoft.com/en-us/powershell/gallery/concepts/package-manifest-affecting-ui (PSGallery UI fields)
- https://learn.microsoft.com/en-us/powershell/scripting/developer/module/how-to-write-a-powershell-module-manifest (`HelpInfoUri`, `Test-ModuleManifest`)
- https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/setting-guidelines-for-repository-contributors (CONTRIBUTING.md auto-detection priority: `.github/` → root → `docs/`)
- Local: `C:\git\azure-analyzer\AzureAnalyzer.psd1`, `C:\git\azure-analyzer\README.md`, `C:\git\azure-analyzer\.github\` (snapshot 2026-04-20)
