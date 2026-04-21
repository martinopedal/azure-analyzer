# LLM-assisted Triage (Track E) Design

Status: Phase 2 design scaffold. Implementation held behind Phase 1 MVP and product validation gate (2 auditor walkthroughs, 2 architect workflows, 1 high-volume tenant dataset run). Tracks issue #433, epic #427.

## Two locked rules

### Rule 1: Rubberduck is the default

The default invocation for every LLM-assisted analysis (prioritized remediation plans, cross-finding correlation, remediation sequencing, narrative tenant summaries) is the multi-model rubberduck trio with 2-of-3 consensus.

A single model will confidently hallucinate a remediation that breaks production. Two models agreeing is a meaningful signal; three models with consensus catches model-specific blindspots.

Single-model mode is opt-in via `-SingleModel` (for speed or cost). The trio is always the default.

### Rule 2: Tier-aware model selection

GitHub Copilot plans gate which models a user can invoke. The CLI must respect this. End-users cannot be forced onto models their plan does not grant.

## Frontier-only invariant: scope clarification

The frontier-only roster (`opus-4.7`, `opus-4.6-1m`, `gpt-5.3-codex`, `gpt-5.4`, `goldeneye`) applies to **internal maintainer agents that run on the azure-analyzer codebase**: code review gates, rubberduck gates on PRs, scaffolding agents, sub-agents spawned by the coordinator. These run on the maintainer's plan and ship quality-affecting output.

**End-user LLM triage (this feature) is a declared exception.** The triage trio is composed from whatever models the running user's Copilot plan grants. This exception is documented in the README so users are not surprised that their Pro-tier triage trio differs from the frontier-only roster used internally.

## Model discovery flow

1. Probe `gh copilot status`. Recent `gh` CLI versions surface the user's Copilot plan.
2. If unsupported or unparseable, require an explicit `-CopilotTier {Pro|Business|Enterprise}` flag (or `$env:AZURE_ANALYZER_COPILOT_TIER`).
3. **No silent fallback.** A misdetected tier could cause the CLI to attempt models the user cannot invoke.
4. **Never use `gh api user`.** That endpoint does not expose Copilot plan info; the original Round 1 design was wrong on this point.

## CLI surface

| Flag | Values | Purpose |
|---|---|---|
| `-TriageModel` | `Auto` (default) or `Explicit:<model-id>` | Auto picks the trio; Explicit forces one model and must be in the user's available roster |
| `-CopilotTier` | `Pro|Business|Enterprise` | Required if `gh copilot status` cannot resolve the plan |
| `-SingleModel` | switch | Opt out of rubberduck trio |
| `$env:AZURE_ANALYZER_COPILOT_TIER` | `Pro|Business|Enterprise` | Environment override equivalent to `-CopilotTier` |

Refusing cross-tier picks: if the user passes `-TriageModel Explicit:<id>` and `<id>` is not in their tier roster, the cmdlet refuses with a clear error message naming the model and the user's available roster.

## Trio composition algorithm

1. Resolve the user's tier (discovery flow above).
2. Enumerate the user's available models for that tier.
3. Rank each model against `config/triage-model-ranking.json`.
4. Pick the top three by rank.
5. Tie-break by **provider diversity**: prefer mixing providers (Anthropic, OpenAI, Google) over three models from the same provider, because rubberduck consensus across providers catches more blindspots.
6. If fewer than three models are available:
   - Default: refuse to run with a clear error pointing at single-model fallback.
   - Configurable: `-SingleModel` opts in to fallback mode with a stderr warning.

## Sanitization

`Remove-Credentials` from `modules/shared/Sanitize.ps1` is applied to:

- Every prompt before it leaves the cmdlet.
- Every response before it is rendered or logged.

Belt-and-braces. LLMs have echoed prompt content verbatim in the past, so the response pass is non-negotiable. A negative Pester test asserts that a poisoned finding field (e.g. an embedded fake token) cannot leak through model echo into rendered output.

## Triage scope

In scope:

- Prioritized remediation plan with ranked "fix in this order because" narrative.
- Cross-finding correlation ("findings 12, 47, 89 all point to the same misconfiguration in subscription X").
- Remediation sequencing ("fix SPN permissions before secret rotation, or rotation will fail").
- Narrative tenant summary: executive-readable one-pager describing posture, severity trend, top risks.

Out of scope:

- Single-finding remediation text (Track D, sourced from the tool itself).
- Auto-apply fixes. Forever out of scope. azure-analyzer is read-only.

## Capability ranking table

Lives at `config/triage-model-ranking.json`. Reviewed by maintainers quarterly. The file commits with a SHA-256 digest in its header so any silent edit is detectable in code review.

This is the only place azure-analyzer makes model-quality judgements on the end-user's behalf.

## Cross references

- `modules/shared/Triage/Invoke-CopilotTriage.ps1` (signatures only at Phase 2 scaffold).
- `tests/triage/Triage.Tests.ps1`, `tests/triage/Triage.Sanitization.Tests.ps1`.
- README "LLM triage" section: end-user vs internal-maintainer roster distinction.
