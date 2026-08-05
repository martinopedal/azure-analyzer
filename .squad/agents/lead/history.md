# Project Context

- **Owner:** martinopedal
- **Project:** ALZ Additional Graph Queries - Azure Landing Zone checklist automation
- **Stack:** PowerShell, KQL (Azure Resource Graph), JSON
- **Created:** 2026-04-14

## Core Context

- **Module Structure:** AzureAnalyzer.psm1 dot-sources root .ps1 files (Invoke-AzureAnalyzer, New-HtmlReport, New-MdReport, modules/**/*.ps1). Keep root files at root to prevent manifest breaks.
- **PSGallery Distribution:** AzureAnalyzer is published to PSGallery (Install-Module -Name AzureAnalyzer). Requires proper GUID and manifest validation.
- **5-Layer ETL Contract:** Any finding field must round-trip through 5 layers: L1 source capture → L2 normalizer → L3 schema (New-FindingRow) → L4 EntityStore → L5 report renderer.
- **Palettes:** WAF posture uses Azure Portal Fluent palette (#0078D4, #D13438, #107C10, #5C2D91, #FF8C00). Defender threat palette uses (#A80000, #D83B01, #FFB900, #0078D4).
- **Markdown Renderer:** Structured around badge row, anchor TOC, executive summary, provider coverage, heat map, top-10 risks, top-30 findings, entity inventory, and run-details tool version block.
- **CI Governance:** Required checks are honest (Analyze (actions)). Signed commits not required. Branch protection enforced.

## Recent History

### 2026-05-12 - PSGallery Publish & Voice Profile
- Issue #963 closed. v1.4.5 published to PSGallery.
- Docs voice profile: neutralize AI language, avoid em/en dashes, limit emojis to checkmarks/crosses.

### 2026-05-13 - Track F Helper Modules Triage (#1056)
- Option B selected: consume renderers directly rather than extracting standalone helper modules (EdgeRelations, Select-ReportArchitecture).

### 2026-05-13 - v1.7.0 Production Readiness Audit
- End-to-end verification of v1.7.0 post-release across 7 audit domains: 8/8 CLEAN.

### 2026-08-05 - Team Update
- Windows CI restored on GitHub-hosted runners (PR #1250 / #1173).
- Native false-positive suppression list shipped (PR #1251 / #1229).
- Backlog of 48 tool-pin PRs deduped down to 16 keepers.