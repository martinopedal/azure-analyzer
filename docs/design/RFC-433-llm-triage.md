# RFC-433: LLM-driven triage with rubberduck and tier-aware model selection (Track E)

Status: Draft
Issue: #433. Epic: #427. Sibling tracks: #428 (attack-path), #429 (resilience),
#430 (viewer), #431 (policy), #432 (tool fidelity).

> Round 3 reconciliation (issue #433 body) is AUTHORITATIVE. Any earlier model
> matrix or tier-detection text is superseded by the reconciled sections.

---

## Problem statement

azure-analyzer produces hundreds to thousands of structured findings across
Azure Resource Graph, Entra ID, GitHub, ADO, and IaC tools. The raw output is
machine-complete but human-overwhelming. Architects and auditors need
last-mile narrative intelligence:

1. **Prioritized remediation** -- "fix these in this order because X depends on Y."
2. **Cross-finding correlation** -- "findings 12, 47, and 89 share a root cause."
3. **Remediation sequencing** -- "rotate the secret after fixing the SPN
   permissions, not before."
4. **Executive narrative** -- a one-pager describing the tenant's security posture,
   severity trends, and top risks.

Today this synthesis is manual. Track E adds opt-in LLM-assisted triage that
leverages the user's GitHub Copilot subscription to generate these narratives,
with multi-model rubberduck consensus as the default to reduce hallucination
risk.

### Why LLM, and why rubberduck?

A single LLM can confidently hallucinate a remediation that breaks production.
Two models agreeing is a meaningful signal. Three models with consensus catches
provider-specific blind spots. The rubberduck trio (2-of-3 consensus) is
therefore the default; single-model mode is an explicit opt-out for speed or
cost.

---

## Goals and non-goals

### Goals

- G1: `Invoke-CopilotTriage` cmdlet that accepts a results.json finding set
  and produces a structured triage output (remediation plan, correlations,
  narrative summary).
- G2: Rubberduck trio as the default invocation. Each model in the trio
  independently generates its analysis; a consensus step merges 2-of-3
  agreements.
- G3: Tier-aware model selection that respects the user's GitHub Copilot
  subscription (Pro / Business / Enterprise). Models discovered at runtime,
  not hardcoded.
- G4: Sanitization of all prompt payloads via `Remove-Credentials` before
  assembly, and sanitization of all LLM responses before display or disk write.
- G5: Feature-flag gating (`-EnableTriage` or config toggle) so the capability
  ships disabled by default during beta.
- G6: Structured JSON output schema that integrates with FindingRow v2 and
  can be rendered in the HTML report Triage panel and the Track V viewer (#430).

### Non-goals

- NG1: Single-finding remediation text (Track D, #432 scope).
- NG2: Auto-apply fixes. azure-analyzer is permanently read-only.
- NG3: Hosting or proxying LLM endpoints. All calls go through the user's
  existing GitHub Copilot API entitlement.
- NG4: Replacing deterministic tool output. LLM triage is additive enrichment,
  never a substitute for structured findings.

---

## Proposed approach

### Provider abstraction

All LLM interaction is mediated through a provider abstraction layer so the
triage engine is decoupled from any single SDK or API surface.

```
                         +---------------------+
                         | Invoke-CopilotTriage|
                         +----------+----------+
                                    |
                         +----------v----------+
                         | Triage Orchestrator  |
                         | (prompt assembly,    |
                         |  trio dispatch,      |
                         |  consensus merge)    |
                         +----------+----------+
                                    |
                    +---------------+---------------+
                    |               |               |
             +------v-----+  +-----v------+  +-----v------+
             | Provider A  |  | Provider B  |  | Provider C  |
             | (Model #1)  |  | (Model #2)  |  | (Model #3)  |
             +------+------+  +------+------+  +------+------+
                    |                |                |
                    +-------+--------+-------+--------+
                            |                |
                     +------v------+  +------v------+
                     | Consensus   |  | Sanitize    |
                     | Engine      |  | (Remove-    |
                     | (2-of-3)    |  |  Credentials)|
                     +-------------+  +-------------+
```

**Provider interface** (PowerShell class or module contract):

```powershell
function Invoke-TriageModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ModelId,
        [Parameter(Mandatory)] [string] $Prompt,
        [Parameter(Mandatory)] [string] $SystemMessage,
        [int] $MaxTokens = 4096,
        [double] $Temperature = 0.2
    )
    # Returns: [PSCustomObject]@{ Response = '...'; TokensUsed = N; ModelId = '...'; LatencyMs = N }
}
```

The initial implementation targets the GitHub Copilot API (via the
`github-copilot-sdk` Python package or direct REST calls to the Copilot
chat completions endpoint). The abstraction allows future providers
(Azure OpenAI, direct Anthropic API) to be added without modifying the
orchestrator.

### Tier detection protocol

Per Round 3 reconciliation, `gh api user` does NOT expose Copilot subscription
info. The detection order is:

1. **Explicit flag**: `-CopilotTier Pro|Business|Enterprise` on the CLI.
2. **Config file**: `config/azure-analyzer.json` key `copilotTier`.
3. **Runtime probe**: `gh copilot status` (returns plan name on recent gh CLI
   versions).
4. **Failure mode**: if none of the above resolves, emit a clear error and
   refuse to run triage. No silent fallback to a default tier.

### Model discovery and capability ranking

Available models are discovered at runtime via `gh copilot models list` (or
the equivalent Copilot REST endpoint). The CLI does NOT hardcode model IDs
per tier.

A vendored, SHA-pinned capability ranking table lives at
`config/triage-model-ranking.json`. This table assigns a numeric rank and
task-class suitability score to each known model. The trio composition
algorithm picks the top-3 available models from the user's roster, maximizing
provider diversity (at most 2 models from the same provider).

Current ranking (v1.1, reviewed 2026-04-21):

| Model              | Rank | Provider   | Notes                          |
|--------------------|------|------------|--------------------------------|
| claude-opus-4.7    | 100  | Anthropic  | Primary rubberduck anchor      |
| claude-opus-4.6-1m | 95   | Anthropic  | Large-context fallback         |
| gpt-5.4            | 90   | OpenAI     | Provider-diversity counterweight|
| gpt-5.3-codex      | 85   | OpenAI     | Code-heavy triage, IaC remediation |
| goldeneye          | 80   | Microsoft  | Internal frontier, last resort |

> **Note**: This ranking table is for *internal maintainer agents* per the
> frontier-only invariant. End-user triage discovers the user's available
> models at runtime and picks the best-3 by capability rank from *their*
> roster, which may include non-frontier models (sonnet, haiku, gpt-4.1, etc.)
> depending on the user's Copilot plan.

### Trio composition algorithm

```
1. Enumerate user's available models via gh copilot models list.
2. Join with config/triage-model-ranking.json to get capability rank.
3. Sort descending by rank.
4. Select top-3, enforcing provider diversity (max 2 per provider).
5. If fewer than 3 models available:
   a. 2 models -> run as duo with 2-of-2 consensus (warn user).
   b. 1 model  -> single-model mode (warn user, require explicit opt-in).
   c. 0 models -> error, refuse to run.
6. If -SingleModel flag is set, skip trio composition and use the
   highest-ranked available model.
```

### Rubberduck consensus engine

Each trio member receives the same system prompt and finding payload. The
consensus engine:

1. Dispatches to all 3 models in parallel (async).
2. Collects structured JSON responses.
3. For each output field (priority ranking, correlations, narrative):
   - If 2-of-3 agree (semantic match via structured comparison), emit the
     consensus value.
   - If all 3 disagree, flag the field as `"consensus": "none"` and include
     all three responses for human review.
4. Disagreement ratio > 50% triggers a warning: "Triage confidence is low;
   manual review recommended."

---

## Token and cost model

### Token budget

| Task class              | Estimated input tokens | Estimated output tokens | Budget cap |
|-------------------------|----------------------|------------------------|------------|
| Remediation plan        | 8,000 - 40,000       | 2,000 - 8,000          | 50,000     |
| Cross-finding correlation | 8,000 - 40,000     | 1,000 - 4,000          | 45,000     |
| Narrative summary       | 4,000 - 20,000       | 1,000 - 3,000          | 25,000     |
| Full triage (all tasks) | 20,000 - 100,000     | 4,000 - 15,000         | 120,000    |

All token counts are *per model*. With rubberduck trio, multiply by 3. With
a large finding set (1000+ findings), the input may be chunked.

### Rate limits and fallback

**End-user models** are subject to GitHub Copilot rate limits per the user's
plan. The triage engine uses `Invoke-WithRetry` from `modules/shared/Retry.ps1`
for per-model retries (3 attempts, exponential backoff: 1s, 4s, 16s with 25%
jitter).

**Model-swap fallback** within the user's tier: if a model is rate-limited
after 3 retries, swap to the next-ranked model in the user's available roster.
Max 5 swaps before failing closed. This mirrors the repo's internal Frontier
Fallback Chain policy (`.copilot/copilot-instructions.md`) but is constrained
to the user's tier -- we never invoke a model the user's plan does not grant.

**Chain exhaustion**: if all available models are rate-limited, emit a clear
error: "All available models are rate-limited. Try again later or use
`-SingleModel` with a specific model ID." Do not silently degrade output.

### Cost transparency

Before executing triage, display an estimate:

```
Triage will invoke 3 models x ~40,000 input tokens each.
Estimated Copilot API usage: ~120,000 input + ~24,000 output tokens.
Proceed? [Y/n]
```

The `-Force` flag suppresses the confirmation prompt.

---

## Security and data exfiltration boundary

### Data flow

```
                  User's machine
+-----------------------------------------------------------+
|                                                           |
|  results.json  -->  Remove-Credentials  -->  Prompt       |
|  entities.json      (scrub tokens,           Assembly     |
|                      keys, SAS,              (structured  |
|                      connection strings)      JSON payload)|
|                                                   |       |
|                                                   v       |
|                                          GitHub Copilot   |
|                                          API endpoint     |
|                                          (user's plan)    |
|                                                   |       |
|                                                   v       |
|                                          Raw LLM response |
|                                                   |       |
|                                                   v       |
|                                          Remove-Credentials|
|                                          (belt & braces)  |
|                                                   |       |
|                                                   v       |
|                                          triage.json      |
|                                          (sanitized)      |
+-----------------------------------------------------------+
```

### Invariants (non-negotiable)

1. **No Azure resource secrets in prompts.** `Remove-Credentials` from
   `modules/shared/Sanitize.ps1` is applied to every field before prompt
   assembly. This covers: GitHub PATs, OAuth tokens, JWTs, OpenAI keys,
   Slack tokens, Azure connection strings, SAS signatures, client secrets.

2. **Canonical entity IDs only.** Raw tenant GUIDs, subscription IDs, and
   resource IDs are included (they are not secrets) but any embedded
   credentials in resource metadata are stripped.

3. **LLM response sanitization.** All model responses pass through
   `Remove-Credentials` before being written to disk or displayed. LLMs
   have been observed echoing back data from prompts.

4. **No data beyond the Copilot API.** The triage engine makes no network
   calls beyond the Copilot chat completions endpoint that the user's plan
   already authorizes. No telemetry, no side-channel exfiltration.

5. **HTTPS only.** All Copilot API calls use HTTPS. HTTP is rejected at the
   provider abstraction layer.

6. **Opt-in only.** Triage does not run unless the user explicitly enables it
   (`-EnableTriage` flag, config toggle, or interactive prompt). No surprise
   data transmission.

### Threat model

| Threat                          | Mitigation                                      |
|---------------------------------|-------------------------------------------------|
| Secret leakage in prompt        | `Remove-Credentials` pre-assembly               |
| LLM echoes secrets from prompt  | `Remove-Credentials` post-response               |
| Model returns malicious content | Output is structured JSON, never executed         |
| Man-in-the-middle on API call   | HTTPS-only, Copilot endpoint TLS                 |
| Cross-tier model invocation     | Runtime tier validation, refuse unknown models   |
| Prompt injection via finding data | Structured JSON payloads, system prompt hardening |

---

## Integration points with existing tools

### Which findings get triaged

All findings in `results.json` that have `Compliant = $false` are candidates
for triage. The triage engine groups findings by:

1. **Severity** (Critical > High > Medium > Low > Info per Schema.ps1 enum).
2. **EntityType** (to enable cross-finding correlation within an entity).
3. **Source tool** (to contextualize remediation advice).

Findings with `Compliant = $true` are excluded from triage input to reduce
token consumption.

### LLM output schema

The triage engine emits `triage.json` with the following envelope:

```json
{
  "SchemaVersion": "1.0",
  "GeneratedAt": "2026-04-23T12:00:00Z",
  "TriageMode": "rubberduck|single",
  "ModelsUsed": ["model-a", "model-b", "model-c"],
  "ConsensusRate": 0.85,
  "RemediationPlan": {
    "Steps": [
      {
        "Priority": 1,
        "FindingIds": ["id-1", "id-2"],
        "Action": "Rotate SPN credentials for app registration X",
        "Rationale": "These findings share a common root cause...",
        "Consensus": "2-of-3",
        "DependsOn": []
      }
    ]
  },
  "Correlations": [
    {
      "GroupId": "corr-001",
      "FindingIds": ["id-12", "id-47", "id-89"],
      "RootCause": "Misconfigured NSG on subnet Y",
      "Consensus": "3-of-3"
    }
  ],
  "NarrativeSummary": {
    "Text": "This tenant has 47 non-compliant findings...",
    "Consensus": "2-of-3",
    "SeverityDistribution": { "Critical": 3, "High": 12, "Medium": 20, "Low": 10, "Info": 2 }
  },
  "LowConfidenceItems": [
    {
      "FindingIds": ["id-55"],
      "Reason": "All three models disagreed on remediation sequence",
      "Responses": { "model-a": "...", "model-b": "...", "model-c": "..." }
    }
  ]
}
```

### FindingRow v2 integration

Triage output does NOT modify existing FindingRow records. Instead, it
produces a parallel triage overlay that references findings by ID. The
report renderers (HTML, MD) and the viewer (#430) read both `results.json`
and `triage.json` to present an integrated view.

Future consideration: a `TriageMetadata` field in FindingRow v2.3
(via `AdditionalFields` hashtable in `New-FindingRow`) could embed
per-finding triage annotations inline. This is deferred until the
triage schema stabilizes.

### Report integration

The HTML report (`New-HtmlReport.ps1`) gains a "Triage" panel that renders:
- The remediation plan as a numbered list with dependency arrows.
- Correlations as grouped finding clusters.
- The narrative summary as a collapsible executive section.
- Consensus indicators (2-of-3, 3-of-3, no consensus) per item.

The Markdown report (`New-MdReport.ps1`) appends a "## AI Triage" section
with the same content in text form.

Both reports read `tools/tool-manifest.json` for triage panel metadata. The
triage tool registers in the manifest with:

```json
{
  "name": "copilot-triage",
  "displayName": "Copilot LLM Triage",
  "scope": "subscription",
  "provider": "copilot",
  "enabled": false,
  "install": { "type": "none" },
  "report": { "color": "#8B5CF6", "icon": "brain" }
}
```

---

## Phased rollout

### Phase 0: RFC (current)

- This document. Design review via 3-model gate per repo contract.
- No implementation code ships in this phase.
- Validate design with 2 auditor walkthroughs and 2 architect workflows.

### Phase 1: Prototype behind feature flag

- `Invoke-CopilotTriage` cmdlet rewritten per this RFC.
- Feature flag: `-EnableTriage` (default: `$false`).
- Config file toggle: `"enableTriage": false` in `config/azure-analyzer.json`.
- Tier detection, model discovery, and provider abstraction implemented.
- Trio dispatch and consensus engine operational.
- No report integration yet; output is `triage.json` only.
- Tests: golden fixtures, deterministic mode, no live LLM calls in CI.

**Entry gate**: Phase 1 of the epic (#427) MVP shipped. Track D (#432) tool
output fidelity complete. Explicit product validation gate passed (2 auditor
walkthroughs, 2 architect workflows, 1 high-volume tenant dataset run).

### Phase 2: Opt-in beta

- Report integration (HTML Triage panel, MD section).
- Viewer #430 Triage panel wired up.
- `-EnableTriage` default remains `$false`.
- Feedback loop: collect consensus rates, token usage, user satisfaction.
- README and PERMISSIONS.md updated to document Copilot API usage.

### Phase 3: GA

- `-EnableTriage` default flips to `$true` (with confirmation prompt).
- Capability ranking table review cadence formalized (quarterly).
- Performance optimizations: finding chunking, parallel model dispatch,
  response caching for repeated runs on the same finding set.

---

## Open questions

1. **Does `gh copilot models list` exist as a stable CLI command?** The
   Round 3 reconciliation references it, but the command may be preview-only
   or unavailable on older `gh` CLI versions. If it does not exist, we need
   an alternative runtime API endpoint or must require the explicit
   `-CopilotTier` flag. This is the highest-risk dependency for the design.

2. **What is the Copilot chat completions endpoint contract for structured
   JSON output?** The triage engine requires JSON-mode responses. If the
   Copilot API does not support `response_format: { type: "json_object" }`,
   the provider abstraction must add parsing and retry logic for malformed
   responses.

3. **How should the consensus engine handle semantic equivalence?** Two
   models may express the same remediation in different words. Exact string
   matching will undercount agreement. Options: (a) structured field
   comparison only (priority rank, finding ID sets), (b) LLM-as-judge for
   semantic similarity (adds cost and latency), (c) embedding-based
   similarity threshold. This requires prototyping.

4. **What is the token budget ceiling per Copilot tier?** GitHub Copilot
   plans impose monthly or per-request token limits that vary by tier.
   These limits are not publicly documented at a granular level. The triage
   engine needs to respect them or risk degraded user experience when the
   user hits their plan ceiling mid-triage.

5. **Should triage results be cached across runs?** If the finding set has
   not changed, re-running triage wastes tokens. A content-hash-based cache
   could skip re-invocation, but cache invalidation (model updates, ranking
   table changes) adds complexity.

6. **How does the Python SDK dependency (`github-copilot-sdk`) interact with
   the PowerShell-native provider abstraction?** The existing
   `Invoke-CopilotTriage.ps1` shells out to Python. The RFC proposes a
   PowerShell-native provider layer. The migration path (keep Python as
   one provider, or fully replace) needs a decision.

7. **Prompt injection resistance for finding data.** Findings contain
   user-controlled strings (resource names, descriptions). The system prompt
   must be hardened against injection. What is the testing strategy for this
   beyond the negative test (poisoned field echo)?

---

## Test strategy

### Principles

- **No live LLM calls in CI.** All tests use pre-recorded golden fixtures.
- **Deterministic mode.** A `-DeterministicMode` flag on
  `Invoke-CopilotTriage` replays canned responses from
  `tests/fixtures/triage/` instead of calling the Copilot API. CI always
  runs in deterministic mode.
- **Golden fixtures.** Realistic finding sets (10, 100, 1000 findings) with
  pre-recorded trio responses and expected consensus output. Stored as JSON
  in `tests/fixtures/triage/`.

### Test categories

| Category                  | Scope                                          | Location                            |
|---------------------------|-------------------------------------------------|-------------------------------------|
| Tier detection            | `gh copilot status` parsing, flag override, config file | `tests/shared/TierDetection.Tests.ps1` |
| Model discovery           | `gh copilot models list` parsing, ranking join  | `tests/shared/ModelDiscovery.Tests.ps1` |
| Trio composition          | Provider diversity, fallback thresholds         | `tests/shared/TrioComposition.Tests.ps1` |
| Prompt assembly           | `Remove-Credentials` integration, token counting | `tests/shared/PromptAssembly.Tests.ps1` |
| Consensus engine          | 2-of-3, 3-of-3, no-consensus, duo, single       | `tests/shared/ConsensusEngine.Tests.ps1` |
| Output schema validation  | triage.json envelope, field completeness         | `tests/shared/TriageSchema.Tests.ps1` |
| Sanitization (negative)   | Poisoned finding field does not leak via echo    | `tests/shared/TriageSanitization.Tests.ps1` |
| Cross-tier rejection      | Explicit model pick outside user's tier is refused | `tests/shared/TierEnforcement.Tests.ps1` |
| Rate-limit fallback       | Model swap within tier on 429, chain exhaustion  | `tests/shared/TriageFallback.Tests.ps1` |
| Report integration        | HTML Triage panel renders from triage.json       | `tests/shared/TriageReport.Tests.ps1` |
| E2E (deterministic)       | Full pipeline with golden fixtures, consensus verified | `tests/e2e/CopilotTriage.E2E.Tests.ps1` |

### Fixture requirements

Each golden fixture set includes:
- `input-findings.json` -- synthetic finding set (10/100/1000 variants).
- `model-a-response.json`, `model-b-response.json`, `model-c-response.json`
  -- pre-recorded model responses.
- `expected-triage.json` -- expected consensus output.
- `poisoned-findings.json` -- finding set with embedded secrets and prompt
  injection attempts for negative testing.

### CI integration

The triage test suite runs as part of `Invoke-Pester -Path .\tests -CI`.
No special CI configuration is needed because deterministic mode uses no
network calls. The test count baseline increases by the number of new tests
(estimated 40-60 tests across all categories).

---

## References

- Issue #433: LLM-assisted triage with rubberduck and tier-aware model selection
- Epic #427: azure-analyzer Phase 2 tracks
- Track D #432: Tool output fidelity (triage input dependency)
- Track V #430: Viewer Triage panel
- `modules/shared/Sanitize.ps1`: `Remove-Credentials` implementation
- `modules/shared/Retry.ps1`: `Invoke-WithRetry` with jittered backoff
- `modules/shared/Schema.ps1`: FindingRow v2.2, entity types, severity enum
- `config/triage-model-ranking.json`: capability ranking table (v1.1)
- `.copilot/copilot-instructions.md`: Frontier Fallback Chain policy
