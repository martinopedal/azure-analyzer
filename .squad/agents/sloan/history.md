# Sloan - Research History

## 2026-04-20 - Validated 5 viz issues (#226–#230) against codebase

**Repo dual-HTML reality:** there are two HTML emitters that both got touched by PRs #211/#220/#222:
- `report-template.html` - model-driven inline JSON template (`renderFindingsTable` line 539, tab switcher line 651). This is the Phase 0 home for new tabs (#220 Resources, #222 Summary).
- `New-HtmlReport.ps1` - legacy server-side HTML generator with its own severity heatmap (line 490), gf-chips filter (line 919), and exec dashboard. PR #221's heatmap lives here.

Any "extends heatmap" issue (#230) must specify which HTML target. Long-term the right move is to port heatmap into the template, then add framework matrix.

**Schema discoveries:**
- `New-FindingRow` (Schema.ps1:135) **already has** `Frameworks` (line 203), `Controls` (line 204), `LearnMoreUrl` (line 197), `Remediation` (line 195). #230's "add Frameworks[]" is a no-op; the real work is **populating** from normalizers and adding `frameworks[]` to `tools/tool-manifest.json`.
- No `RuleId` field - blocks clean #227 aggregation. Recommend adding as nullable optional before #227 lands.
- #228 risks 3 overlapping URL fields (`Remediation` text / `LearnMoreUrl` / proposed `RemediationUrl`). Prefer reusing `LearnMoreUrl` with column rename.

**Test conventions:** `tests/shared/HtmlReport.Tests.ps1` is the canonical render-test home (extended by both #220 and #222). `tests/shared/Schema.Tests.ps1` for schema deltas. Per-tool render fixtures go in `tests/normalizers/Normalize-*.Tests.ps1`.

**Security invariants to enforce on viz PRs:**
- All URL fields → `Remove-Credentials` before HTML emit (Defender SAS-tokens).
- HTTPS-only allowlist; no `javascript:` URLs in deep-link column.
- No new JS dependencies - vanilla JS + native `<details>` only (matches stated invariant).

**Verdicts:** ✅ #226, #229. 🟡 #227 (RuleId), #228 (URL field strategy), #230 (HTML target).
