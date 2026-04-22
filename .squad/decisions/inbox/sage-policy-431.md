# Decision: sage-policy Track C scaffold (#431)

**Date:** scaffold landed
**Author:** sage-policy
**Branch:** feat/policy-431
**Issue:** #431
**Foundation dependency:** #435 (4 new edges land there)
**Epic:** #427

## What landed

DRAFT PR with design + algorithm + scaffold only. Stability hold honored: zero hot-file edits, zero catalog data vendored, zero behavior change.

Files:
- `docs/design/policy-enforcement.md` — 4 edges, heatmap, AzAdvertizer + ALZ integration, three UI pills (`built-in` / `AzAdvertizer` / `ALZ`), catalog-vintage banner, `report-manifest.json` audit shape.
- `docs/design/alz-scoring-algorithm.md` — locked Round 2 weighted formula (0.40 exact + 0.30 structural + 0.20 renames + 0.10 Levenshtein), curated rename table, threshold semantics (>=0.80 full / 0.50-0.79 partial / <0.50 fallback), `-AlzReferenceMode {Auto|Force|Off}`, three worked examples with computed scores.
- `modules/shared/Policy/PolicyEnforcementRenderer.ps1` — function signatures only (`New-PolicyEnforcementGraph`, `Get-ComplianceHeatmapColor`, `Format-ExemptionTooltip`).
- `modules/shared/Policy/AlzMatcher.ps1` — function signatures (`Invoke-AlzHierarchyMatch` + 4 component functions + `Get-AlzActivationDecision`).
- `modules/shared/Policy/AzAdvertizerLookup.ps1` — function signatures (`Get-PolicySuggestionsForFinding`, `Import-FindingToPolicyMap`, `Get-CatalogVintage`).
- `modules/shared/Policy/finding-to-policy-map.json` — 7 sample entries demonstrating schema (finding-type -> AzAdvertizer / ALZ suggestions with scope hints).
- `tests/policy/AlzMatcher.Tests.ps1` — 5 `-Skip` test cases covering the three worked examples + CLI flag behavior.
- `CHANGELOG.md` — single Added entry under [1.2.0 - Unreleased].

## Decisions made

- ALZ canonical name set fixed at 10 nodes (`Root`, `Platform`, `Management`, `Connectivity`, `Identity`, `Landing Zones`, `Corp`, `Online`, `Decommissioned`, `Sandbox`). `Confidential Corp` / `Confidential Online` excluded from the scoring set; they are catalog-only and do not affect the match score.
- Whole-name matching only; substring matches explicitly disallowed to keep scoring deterministic and auditable.
- `-AlzReferenceMode Force` still computes the score and writes it to the manifest, but renders a `force-overridden` badge if score < 0.80. This preserves auditability when the user overrides Auto.
- ALZ suggestions in the partial band (0.50-0.79) render with a `partial-match` badge alongside the `ALZ` pill, making the lower confidence visible to the consumer.
- Catalog refresh stays manual (quarterly cadence) — SHA-pinning is the security boundary, automation would break it.

## Deferred (not in this PR)

- Vendoring AzAdvertizer + ALZ JSON catalogs (data ingestion follow-up after Foundation #435 merges).
- Schema.ps1 edits for the 4 new edges (Foundation PR #435).
- AzGovViz normalizer edge emission (per-tool PR after Foundation).
- Renderer + lookup implementation, `report-manifest.json` writer integration.
- Implementation tests (the 3 worked examples flip from `-Skip` to live once `Invoke-AlzHierarchyMatch` is implemented).

## Pester

1518 passed, 0 failed, 10 skipped (5 new `-Skip` placeholders from this PR). Baseline green.

## Open questions for review

1. Is the canonical 10-node set the right boundary, or should `Confidential Corp` / `Confidential Online` count toward the score? Current proposal: no, because tenants legitimately omit them.
2. The Levenshtein component degenerates to 1.0 when no nodes remain unmatched. Confirm this is the right default versus 0.0; the doc argues 1.0 because nothing failed to match.
3. `Force` mode badging: badge or no badge when score < 0.80? Proposal: badge, for auditability.
