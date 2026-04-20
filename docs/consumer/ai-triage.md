# Optional: AI-Assisted Triage (requires GitHub Copilot license)

> **This feature is entirely optional.** Azure Analyzer works fully without it — all seven assessment tools, unified JSON output, and HTML/Markdown reports are completely independent of AI triage. The triage is a bonus enrichment layer for teams that have GitHub Copilot.

When enabled, AI triage enriches non-compliant findings with priority ranking, risk context, and actionable remediation guidance using the [GitHub Copilot SDK](https://github.com/github/copilot-sdk).

> **⚠️ Preview SDK:** The `github-copilot-sdk` package is currently at version **0.1.x (preview)**. The API surface may change in future releases. Pin your version if stability is critical: `pip install github-copilot-sdk==0.1.*`

## What it does

With `-EnableAiTriage`, after all assessment tools finish:

1. Reads `output/results.json`
2. Groups non-compliant findings by severity into batches
3. Sends each batch to GitHub Copilot for expert analysis
4. Enriches each finding with:
   - **AiPriority** — fix-first ranking (1 = most urgent) based on blast radius and exploitability
   - **AiRiskContext** — what could go wrong if this finding is not addressed
   - **AiRemediation** — concrete remediation steps (not just "see docs")
   - **AiRelatedFindings** — IDs of other findings sharing a root cause
5. Writes `output/triage.json` with all original findings plus the AI fields

Reports automatically include an AI Triage Summary section when `triage.json` is present.

**Without `-EnableAiTriage`**, none of this runs. No Python is called, no token is checked, no warnings appear. The feature has zero footprint when disabled.

## ⚠️ Data privacy warning

**When AI triage is enabled, non-compliant finding data is sent to GitHub Copilot services.**

This includes finding titles, severity, details, remediation text, and Azure resource IDs. This data is processed under your existing [GitHub Copilot agreement](https://github.com/features/copilot).

- **Compliant findings are never sent** — only non-compliant findings are transmitted
- **Strictly opt-in** — nothing is sent unless you explicitly pass `-EnableAiTriage`
- **Without the flag, zero data leaves your machine**
- A privacy notice is displayed in the console before any data is sent

## Requirements

### GitHub Copilot license

AI triage requires an active **GitHub Copilot** subscription — Individual, Business, or Enterprise. Without a Copilot license, you cannot use this feature. The triage calls count against your normal Copilot usage quota (not a separately billed API).

### Setup steps

These are only needed if you choose to use AI triage:

1. **Python 3.10+** — install from [python.org](https://www.python.org/downloads/)
2. **GitHub Copilot SDK** — install manually (this is NOT auto-installed):
   ```bash
   pip install github-copilot-sdk
   ```
3. **Copilot-scoped token** — create a PAT at [github.com/settings/tokens](https://github.com/settings/tokens) with the `copilot` scope, then set it:
   ```bash
   export COPILOT_GITHUB_TOKEN="github_pat_..."
   ```

### Authentication

The SDK resolves credentials in this order:

1. Token passed explicitly (azure-analyzer sets this from env vars below)
2. `GITHUB_TOKEN` environment variable
3. `gh auth login` session (GitHub CLI)

Azure-analyzer checks these env vars and passes the first one found to the SDK:

| Token variable | Priority |
|---|---|
| `COPILOT_GITHUB_TOKEN` | Checked first (recommended) |
| `GH_TOKEN` | Checked second |
| `GITHUB_TOKEN` | Checked third |

**Supported token types:** `github_pat_` (PAT), `gho_` (OAuth), `ghu_` (user).
**NOT supported:** `ghs_` (GitHub Actions GITHUB_TOKEN) — these do not have Copilot API access.

## Usage

```powershell
# With AI triage (optional)
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -EnableAiTriage

# Without AI triage (default — the tool works exactly the same)
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..."
```

If any prerequisite is missing when `-EnableAiTriage` is passed, the tool warns with a specific message and continues without AI enrichment:

| Missing prerequisite | Warning message |
|---|---|
| Python not installed | "AI triage requires Python 3.10+. Skipping." |
| SDK not installed | "AI triage requires github-copilot-sdk. Install with: pip install github-copilot-sdk. Skipping." |
| No token / no license | "AI triage requires a GitHub Copilot license. Set COPILOT_GITHUB_TOKEN with a PAT that has the 'copilot' scope. Skipping." |

## Model selection

The script discovers available models at runtime via `list_models()` and selects from a preferred list:

| Preference | Model | Notes |
|----------|-------|-------|
| 1st choice | `gpt-4.1` | Cost-effective, good at structured JSON |
| 2nd choice | `claude-sonnet-4` | Strong reasoning fallback |
| 3rd choice | `gpt-5-mini` | Lightweight last-resort |

If none of the preferred models are available (model names may change as the SDK evolves), the script falls back to whatever models `list_models()` returns. Each model is retried up to 3 times with exponential backoff before trying the next.
