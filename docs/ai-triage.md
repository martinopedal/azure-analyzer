# Optional: AI-Assisted Triage (requires GitHub Copilot license)

> **This feature is entirely optional.** Azure Analyzer works fully without it — all seven assessment tools, unified JSON output, and HTML/Markdown reports are completely independent of AI triage. The triage is a bonus enrichment layer for teams that have GitHub Copilot.

When enabled, AI triage enriches non-compliant findings with priority ranking, risk context, and actionable remediation guidance using the [GitHub Copilot SDK](https://github.com/github/copilot-sdk).

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

## Models and fallback chain

| Priority | Model | Notes |
|----------|-------|-------|
| 1 (default) | `gpt-4.1` | Cost-effective, good at structured JSON |
| 2 (fallback) | `claude-sonnet-4` | Strong reasoning fallback |
| 3 (fallback) | `gpt-5-mini` | Lightweight last-resort |

Each model is retried up to 3 times with exponential backoff before falling back.

## Privacy and data handling

> **When AI triage is enabled**, non-compliant finding data (titles, details, resource IDs, remediation text) is sent to the **GitHub Copilot API**.

- Data is processed under your existing [GitHub Copilot agreement](https://github.com/features/copilot)
- Compliant findings are **never** sent
- The feature is strictly **opt-in** — nothing is sent unless you pass `-EnableAiTriage`
- Without the flag, zero data leaves your machine
