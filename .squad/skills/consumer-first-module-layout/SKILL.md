# Skill - Consumer-First Module Layout (PowerShell / GitHub)

> Reusable pattern catalog for restructuring a PowerShell module repo so that consumers (install → invoke → read output) hit zero friction at the GitHub root, while contributor material is preserved but de-emphasised.

## When to use this skill

- The repo ships a PowerShell module (PSGallery-published or `git clone`-consumed).
- The root README, root file list, or both are dominated by contributor-facing content.
- Maintainers want the GitHub landing page to read like a product page, not a workshop floor.

## The pattern

### README skeleton (in this exact order)

1. One-line tagline
2. Status badges (CI, PSGallery downloads, license)
3. **Install** - copy-pasteable, above the fold
4. **Quick start** - single minimal end-to-end scenario
5. Scenarios / recipes (2–5, named)
6. "Reading the output" or equivalent consumer outcome section
7. What it covers (collapsible if long)
8. Documentation index → links into `docs/`
9. Contributing - one paragraph, links to `.github/CONTRIBUTING.md` + `docs/contributor/`
10. License

### Repo root layout

```
README.md, LICENSE, CHANGELOG.md       # MUST stay at root
<Module>.psd1, <Module>.psm1           # MUST stay at root
<entry-point>.ps1                      # primary consumer CLI at root
modules/, queries/, templates/, samples/, tests/, tools/, scripts/  # implementation
docs/
  guides/         # consumer recipes
  reference/      # cmdlet reference (PlatyPS)
  governance/     # AI/permissions/third-party notices
  contributor/    # architecture, dev-setup, internal contracts
.github/
  CONTRIBUTING.md, SECURITY.md, CODE_OF_CONDUCT.md   # MOVE here from root
  CODEOWNERS, pull_request_template.md, ISSUE_TEMPLATE/, dependabot.yml
.copilot/, .squad/, …                  # dotfile dirs collapse to bottom - leave alone
```

## Hard rules (do not violate)

| Rule | Why | Source |
|---|---|---|
| `LICENSE` stays at root | GitHub license detector + sidebar chip require root | GitHub Docs community-health files |
| `CHANGELOG.md` stays at root | PSGallery `ReleaseNotes` typically links to it | learn.microsoft.com/powershell/gallery |
| `CONTRIBUTING.md` only in `{.github/, root, docs/}` | GitHub auto-detection priority `.github/` → root → `docs/`; anywhere else breaks the Contributing tab + PR-form link | https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/setting-guidelines-for-repository-contributors |
| `SECURITY.md`, `CODE_OF_CONDUCT.md` follow same rule | Same auto-detection mechanism | Same source |
| Install snippet must be above the fold | All consumer-friendly references (PSRule, Pester, PSReadLine, ImportExcel, MS Graph PS SDK) place install in the first scroll | Repo READMEs |
| Manifest must have `PrivateData.PSData` before first publish | PSGallery page UI is driven entirely by these fields (ProjectUri, LicenseUri, IconUri, ReleaseNotes, Tags) | https://learn.microsoft.com/en-us/powershell/gallery/concepts/package-manifest-affecting-ui |

## Restructure PR contract

Every consumer-first restructure PR MUST include, in a single commit train:

1. The file moves themselves.
2. Updates to every internal link (grep-audit `'README.md'`, `'CONTRIBUTING.md'`, `'SECURITY.md'`, `'docs/'`, plus any project-specific doc filenames across `**/*.{ps1,psm1,yml,yaml,md}`).
3. Update to `.github/CODEOWNERS` paths.
4. Update to `<Module>.psd1` `PrivateData.PSData.ProjectUri` if it referenced a moved path.
5. 1-line stub at each old root-level doc location pointing to the new path (kept for one release cycle, then removed). Protects external bookmarks.
6. `Test-ModuleManifest <Module>.psd1` passes.
7. Existing test suite passes (no test files moved).

## Anti-patterns (caught in research)

- Moving `CONTRIBUTING.md` into `docs/contributor/` (breaks GitHub's auto-detection - must stay in `.github/`, root, or top-level `docs/`).
- Renaming README headings without recording the old anchor (silently breaks deep links - GitHub does not auto-redirect markdown anchors).
- Splitting a one-page README into many short files (increases consumer friction).
- Leaving the manifest `PrivateData.PSData` block empty when publishing to PSGallery (dead-end package page).
- Burying the install snippet under architecture diagrams or governance disclaimers.

## Reference repos to study

- https://github.com/microsoft/PSRule.Rules.Azure
- https://github.com/pester/Pester
- https://github.com/PowerShell/PSReadLine
- https://github.com/dfinke/ImportExcel
- https://github.com/microsoftgraph/msgraph-sdk-powershell

## Provenance

Extracted from research brief `.squad/decisions/inbox/sage-consumer-module-patterns-2026-04-20T12-17-17Z.md` (Sage, 2026-04-20). All claims in this skill are URL-cited in the source brief.
