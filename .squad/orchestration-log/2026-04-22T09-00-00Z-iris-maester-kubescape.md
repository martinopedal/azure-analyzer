# Orchestration Log: Iris — Maester + Kubescape UI Pattern Deep-Dives

**Started:** 2026-04-22T09:00:00Z  
**Agent:** Iris (Identity & Entra)  
**Status:** Complete

## Summary

Produced two research briefs for the report-UX redesign arc:

1. **Maester UI patterns** (`iris-maester-ui-patterns.md`, 35 KB) — full IA of Maester's native HTML report, 10 ranked UI primitives to steal, severity/status color palette (WCAG-AA), per-test row layout, evidence/remediation panel spec, compliance-framework badge taxonomy (EIDSCA/CIS/MITRE/eIDAS2/NIST/ORCA), and a 14-field ETL gap matrix tracing every dropped Maester field through all 5 layers (wrapper → normalizer → schema → entity store → report).

2. **Kubescape UI patterns** (`iris-kubescape-ui-patterns.md`, 44 KB) — v2 JSON schema walkthrough, ARMO dashboard IA, 10 ranked UI primitives (posture-score gauge, framework cards, fixPaths YAML diffs), severity-from-scoreFactor bands, 17-field ETL gap matrix, per-resource granularity recommendation (one FindingRow per controlID×resourceID), and cross-tool unification spec (shared `<framework-chip>` component, framework-keyed not tool-keyed colors).

## Key Findings

- Maester `Tags` (compliance framework membership) is **completely dropped** — the single biggest gap across all tools.
- Maester `TestRemediation` and `HelpUrl` are hard-coded to empty strings — easy fixes.
- Kubescape wrapper only reads `summaryDetails.controls` rollup, never `results[]` — loses all per-resource granularity and fixPaths.
- Both tools need the same 3 schema additions: `New-FindingRow -Properties`, envelope v3.2 `RunContexts`, shared `Get-FrameworkFromTag` classifier.
- Unified framework-chip palette locked: CIS=amber, MITRE=red, NIST=slate, EIDSCA=blue, eIDAS2=violet, SOC=teal.

## Outputs

- `.squad/decisions/inbox/iris-maester-ui-patterns.md`
- `.squad/decisions/inbox/iris-kubescape-ui-patterns.md`
- Issues referenced: #305 (Maester ETL), #306 (Kubescape ETL)
