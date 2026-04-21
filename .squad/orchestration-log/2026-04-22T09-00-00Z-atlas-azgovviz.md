# Orchestration Log: Atlas — AzGovViz UI Pattern Deep-Dive

**Started:** 2026-04-22T09:00:00Z  
**Agent:** Atlas (ARG & Governance)  
**Status:** Complete

## Summary

Produced a single research brief: **AzGovViz UI patterns** (`atlas-azgovviz-ui-patterns.md`, 26 KB) — full IA of the AzGovViz single-file HTML dashboard (4 panes: HierarchyMap, TenantSummary, DefinitionInsights, ScopeInsights), 8 ranked UI primitives, color/typography extraction from live CSS, wrapper gap analysis, and the architectural verdict on single-scroll vs TabStrip.

## Architecture Decision

**Single-page scroll with sticky in-page anchor pills. No JS tabs.** AzGovViz's TabStrip breaks Ctrl+F search (`display:none` hides content), puts the findings table behind a click (wrong CISO default), and adds JS state management cost. Sticky anchor pills give AzGovViz's density without the JS plumbing.

## Key Findings

- CSS-only management-group tree (`<ul><li>` + `::before/::after` connectors, ~40 lines CSS, no JS) — highest-value visual primitive.
- TableFilter (vanilla JS, MIT, ~80KB) replaces jQuery DataTables — already battle-tested in AzGovViz.
- `*_HierarchyMap.json` **not parsed** by our wrapper — blocks MG ancestry breadcrumbs.
- AzAdvertizer URLs (per-definition evidence links) **not preserved**.
- AzGovViz severity colors are icon-only; text-on-chip requires darkened variants for WCAG-AA.

## Outputs

- `.squad/decisions/inbox/atlas-azgovviz-ui-patterns.md`
- Issue referenced: #307 (AzGovViz ETL)
