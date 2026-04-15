# AI-Assisted Triage

Optional AI triage using the GitHub Copilot SDK. Enabled with `-EnableAiTriage`.

## Setup
1. Python 3.10+
2. `pip install github-copilot-sdk`
3. Set `COPILOT_GITHUB_TOKEN`, `GH_TOKEN`, or `GITHUB_TOKEN` (PAT, NOT ghs_)

## Usage
```powershell
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -EnableAiTriage
```

## Output
Enriches each finding with: AiPriority, AiRiskContext, AiRemediation, AiRelatedFindings.
Writes `output/triage.json`. Reports auto-include triage section.

## Models
gpt-4.1 (default) > claude-sonnet-4 > gpt-5-mini. 3 retries with exponential backoff.

## Privacy
Non-compliant finding data sent to GitHub Copilot API. Opt-in only. Uses Copilot quota.
