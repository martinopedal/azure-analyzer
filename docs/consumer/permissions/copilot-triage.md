# Copilot AI Triage (opt-in) - Required Permissions

**Display name:** Copilot AI Triage

**Scope:** repository | **Provider:** cli

> Disabled by default in `tools/tool-manifest.json`. Only runs when the user explicitly opts in with `-EnableAiTriage`.

When enabled, non-compliant findings are sent to GitHub Copilot for AI analysis and remediation suggestions. **This is completely optional.**

## Required credentials

| Requirement | Details |
|-------------|---------|
| **License** | GitHub Copilot Individual, Business, or Enterprise (if not licensed, AI triage is skipped) |
| **Token** | PAT with `copilot` scope, or existing `GITHUB_TOKEN` if already authenticated |
| **Environment variable** | `COPILOT_GITHUB_TOKEN` or `GITHUB_TOKEN` (`ghs_` tokens are not supported) |
| **Privacy** | No data is sent to Copilot services unless `-EnableAiTriage` flag is used |

## How to grant

```powershell
# 1. Create Copilot-scoped PAT at https://github.com/settings/personal-access-tokens/new
#    Permissions: Copilot scope only
#    Name: azure-analyzer-copilot
#    Expiration: 90 days

# 2. Set environment variable
$env:COPILOT_GITHUB_TOKEN = "ghp_..."

# 3. Run with AI triage enabled
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -EnableAiTriage

# If you don't have Copilot licensed, the tool skips this step with a warning
```

## Privacy note

When Copilot SDK is enabled, only non-compliant finding details (title, severity, remediation) are sent for analysis. No credential or resource data is included.

See also: [`docs/consumer/ai-triage.md`](../ai-triage.md) for the AI triage workflow and prompt design.
