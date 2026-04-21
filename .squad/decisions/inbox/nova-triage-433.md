# nova-triage / Track E scaffold (#433)

**Branch:** `feat/triage-433`
**PR:** draft (Phase 2 hold)

## Summary

Scaffolded Track E (LLM-assisted triage with rubberduck + tier-aware model selection):

- `docs/design/llm-triage.md` — design doc with both locked rules, frontier-only invariant scope clarification (internal maintainer agents vs end-user triage), model discovery flow (`gh copilot status`, no `gh api user`, no silent fallback), CLI surface, trio composition algorithm with provider-diversity tie-break, sanitization contract, and explicit in/out of scope.
- `config/triage-model-ranking.json` — capability ranking template with `_header` block reserving a SHA-256 slot reviewed quarterly.
- `modules/shared/Triage/Invoke-CopilotTriage.ps1` — signatures only for `Invoke-CopilotTriage`, `Get-AvailableModelsFromCopilotPlan`, `Select-TriageTrio`, `Invoke-PromptSanitization`, `Invoke-ResponseSanitization`. All bodies throw `NotImplementedException`.
- `tests/triage/Triage.Tests.ps1` and `Triage.Sanitization.Tests.ps1` — Pester `-Skip` placeholders for trio selection by tier, explicit-model refusal, single-model fallback warning, sub-3 model behavior, prompt and response sanitization (echo leakage is the most security-critical case).

## Decisions worth recording

- Frontier-only invariant scope is clarified in the design doc and intended for the README in Phase 2. Internal agents stay frontier-only; end-user triage runs on whatever models the user's Copilot plan grants.
- Trio composition prefers provider diversity (Anthropic / OpenAI / Google) as a rubberduck signal-strength heuristic, not just raw rank.
- Default behaviour when fewer than 3 models are available: refuse, with `-SingleModel` as the explicit opt-in.
- Tier discovery: `gh copilot status` first, then required `-CopilotTier` flag or env var. No silent fallback. `gh api user` is explicitly banned because it does not expose plan info.
- Capability ranking JSON ships with a `_header.sha256` slot. Quarterly review by maintainers.

## Hot files avoided

No edits to `Schema.ps1`, `Invoke-AzureAnalyzer.ps1`, `New-HtmlReport.ps1`, or `tools/tool-manifest.json`. No actual LLM calls. Foundation dependency on #435 is respected — discovery implementation deferred.

## Tests

`Invoke-Pester .\tests\triage -CI` → 13 skipped, 0 failed. Existing 842/842 baseline untouched (no edits outside new files).

## Follow-ups for Phase 2

- Implement `gh copilot status` parser + tier resolution.
- Wire `Remove-Credentials` into `Invoke-PromptSanitization` / `Invoke-ResponseSanitization` and turn the Pester `-Skip` cases into real tests.
- README section for end-user vs internal-maintainer roster distinction.
- CHANGELOG entry on shipping Phase 2.
- PERMISSIONS note that Copilot API calls are made.
