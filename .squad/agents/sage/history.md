# Project Context

- **Owner:** martinopedal
- **Project:** ALZ Additional Graph Queries - Research and tool ecosystem scouting
- **Stack:** Web research, GitHub API, Microsoft Learn, public tool evaluation
- **Created:** 2026-04-14

## Learnings

<!-- Append new learnings below. Each entry is something lasting about the project. -->

### 2026-04-20 - Consumer-first PowerShell module layout
- Researched 6 reference repos (PSRule for Azure, Pester, PSReadLine, ImportExcel, MS Graph PS SDK, AVM Bicep) plus SecretManagement as anti-example.
- Distilled README skeleton: tagline → badges → install → quick start → scenarios → docs link → contributing (1 paragraph) → license.
- Key GitHub mechanic: `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md` are auto-detected ONLY in `{.github/, root, docs/}` (priority `.github/` first). Moving them anywhere else breaks the GitHub "Contributing" tab + PR-form link. Source: GitHub Docs community-health-files page.
- `LICENSE` and `CHANGELOG.md` MUST stay at root - `LICENSE` for GitHub's license detector, `CHANGELOG.md` because PSGallery `ReleaseNotes` typically links there.
- PSGallery package page is driven entirely by `PrivateData.PSData` (ProjectUri/LicenseUri/IconUri/ReleaseNotes/Tags) + manifest root fields. Source: learn.microsoft.com/powershell/gallery/concepts/package-manifest-affecting-ui.
- **azure-analyzer's `AzureAnalyzer.psd1` has NO `PrivateData.PSData` block at all** - must be added before first PSGallery publish or the package page will be a dead-end.
- **Placeholder GUID** in `AzureAnalyzer.psd1` (`0e0f0e0f-…`) must be regenerated before first publish.
- Restructure must include a grep-audit of hardcoded doc paths in `*.ps1`, `*.psm1`, `*.yml`, `*.md` and a `CODEOWNERS` audit - same-PR or it silently breaks.
- Brief delivered to `.squad/decisions/inbox/sage-consumer-module-patterns-2026-04-20T12-17-17Z.md`.
