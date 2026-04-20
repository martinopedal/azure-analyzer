# Project Context

- **Owner:** martinopedal
- **Project:** ALZ Additional Graph Queries - Azure Landing Zone checklist automation
- **Stack:** PowerShell, KQL (Azure Resource Graph), JSON
- **Created:** 2026-04-14

## Work Completed

- **2024-12-19:** Established routing infrastructure (routing.md with 11 rules, Module Ownership section)
- **2024-12-19:** Initialized casting/registry.json with 6 agents (Lead, Forge, Remote Fixer, Rubber Duck, Sentinel, Ralph)
- **2024-12-19:** Commit 85d8c5e - Routing + registry foundation for squad orchestration

## Learnings

<!-- Append new learnings below. Each entry is something lasting about the project. -->

### 2026-04-20 - Doc-restructure audit (consumer-first directive)

- **Module consumption is clone-and-import, not PSGallery.** `AzureAnalyzer.psd1` has no `PrivateData.PSData` (no Tags/Uris/ReleaseNotes) and the GUID is a placeholder (`0e0f0e0f-…`). Any PSGallery push needs a real GUID rotation first.
- **`AzureAnalyzer.psm1` dot-sources four root-level `.ps1` files** (`Invoke-AzureAnalyzer`, `New-HtmlReport`, `New-MdReport`, plus globs `modules/**/*.ps1`). Moving any of those four into `src/` is a manifest-breaking change - keep them at root.
- **README is 493 lines / ~54 KB** with 30+ headings. Quickstart at line 9 but Prereqs at line 319 and Permissions at line 607 - consumers hit auth errors before they hit the docs that explain auth.
- **`docs/` already mixes audiences**: `ARCHITECTURE.md` + `CONTRIBUTING-TOOLS.md` + `proposals/` (contributor) sit beside `continuous-control.md` + `sinks/` + `ai-triage.md` + `gitleaks-pattern-tuning.md` (advanced consumer). A `consumer/` vs `contributor/` split is the natural cut.
- **Root pollution to fix**: `pester.log`, `retry.log`, `testResults.xml` are committed build artefacts. `report-template.html` (40 KB) is an internal renderer asset masquerading as a root doc - belongs in `templates/`.
- **5 `output*/` directories at repo root** - confirm intent before gitignoring.
- **`.gitattributes` already hides `.squad/` + squad workflows from archive zips** via `export-ignore` - so consumer-vs-contributor separation for archive consumers is partially done; the remaining gap is the rendered `docs/` tree on github.com.
- **Inbound link surface to redirect**: `docs/ARCHITECTURE.md`, `docs/CONTRIBUTING-TOOLS.md`, `docs/continuous-control.md`, `docs/sinks/log-analytics.md`, `docs/ai-triage.md`, `docs/gitleaks-pattern-tuning.md`. README links into all six; CHANGELOG history likely too. Stub-with-meta-refresh pattern is the safe play.
