# Orchestration Log: Forge — CLI Tools UI Patterns (Trivy/Infracost/Scorecard)

**Started:** 2026-04-22T09:00:00Z  
**Agent:** Forge (Platform Automation & DevOps)  
**Status:** Complete

## Summary

Produced a research brief: **CLI tools UI patterns** (`forge-cli-tools-ui-patterns.md`, 55 KB) — deep-dives on Trivy, Infracost, and OpenSSF Scorecard native HTML/CLI outputs, recommended row layouts for each in the unified report, severity mappings, and full ETL gap matrices per tool.

## Bug Uncovered

**Scorecard severity inversion** — wrapper maps score `-1` (errored check) to `High` severity. Errored ≠ failed; a `-1` means Scorecard couldn't reach an API, not that the check failed. Should be `Info`. Additionally, score `0` (true failure, e.g. 15 known CVEs) maps to `High` instead of `Critical`, understating the urgency.

## Key Findings

- Trivy: wrapper passes `--scanners vuln` only — misses misconfig and secret scan types entirely. CVSS scores, CWE IDs, per-layer PkgPath, full References array all dropped.
- Infracost: wrapper only calls `breakdown` (no `diff`), losing cost-delta signal. `MonthlyCost` and `Currency` bolted on via `Add-Member` — survive JSON but not schema validation.
- Scorecard: aggregate score (0-10, the hero KPI) never captured. Per-check `details[]` (file:line evidence) dropped. Should be rendered as a dedicated hero card, not mixed into the findings table.
- Cross-tool: recommended unified severity palette (Trivy's hex codes as canonical), scan-target badge convention, SARIF as universal renderer path.

## Outputs

- `.squad/decisions/inbox/forge-cli-tools-ui-patterns.md`
- Issues referenced: #311 (Trivy), #312 (Infracost), #313 (Scorecard)
