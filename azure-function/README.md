# azure-analyzer Function App (continuous control mode, #165)

PowerShell Function App that wraps `Invoke-AzureAnalyzer.ps1` for unattended,
scheduled scans. Two triggers, one orchestrator:

- **`TimerScan/`** — runs daily at 06:00 UTC (NCRONTAB `0 0 6 * * *`). Scan
  parameters come from Function App settings.
- **`HttpScan/`** — POST endpoint (`authLevel: function`, per-function key)
  for on-demand / break-glass scans. Body fields override the env defaults.
  `includeTools` values are validated against an allow-list.

Both triggers share `Shared/Invoke-FunctionScan.ps1`, which:

1. Resolves `subscriptionId`, `tenantId`, `includeTools` (env or request).
2. Invokes the orchestrator with a bounded toolset (default profile picks a
   subset that fits the 10-minute Consumption-plan timeout).
3. Optionally forwards `entities.json` to the existing Log Analytics sink
   (`modules/sinks/Send-FindingsToLogAnalytics.ps1`, #162) when
   `DCE_ENDPOINT` + `DCR_IMMUTABLE_ID` are set. No new sink module is
   introduced.

## Required app settings

| Setting | Required | Notes |
|---|---|---|
| `AZURE_ANALYZER_SUBSCRIPTION_ID` | yes (timer) | Default subscription scope |
| `AZURE_ANALYZER_TENANT_ID` | recommended | Used by the WARA collector |
| `AZURE_ANALYZER_INCLUDE_TOOLS` | recommended | CSV of tool names; leave unset to run all (will exceed the 10-min Consumption cap) |
| `DCE_ENDPOINT` | optional | Logs Ingestion DCE; sink is skipped when empty |
| `DCR_IMMUTABLE_ID` | optional | DCR id paired with `DCE_ENDPOINT` |
| `FINDINGS_STREAM` / `ENTITIES_STREAM` | optional | Stream names; default `Custom-AzureAnalyzerFindings/Entities` |
| `SINK_DRY_RUN` | optional | Set to `true` to write the sink payload to disk instead of POSTing |

## Identity

The Function App must run with a managed identity (system- or user-assigned)
holding **Reader** at the target subscription / management group, plus
**Monitoring Metrics Publisher** on the DCR if the sink is enabled. See
[`PERMISSIONS.md`](../PERMISSIONS.md#continuous-control-function-app-165).

## Timeout caveat

Consumption plan caps every invocation at **10 minutes**. Full scans
typically take longer; the timer trigger therefore restricts itself to a
small toolset by default (`azqr`, `psrule`). For a full daily sweep, deploy
on the **Premium** plan or **Container Apps** (recommended). Bicep
deployment templates are tracked in a separate follow-up issue.

## Deployment

Deployment automation (Bicep / Terraform) is **out of scope for #165** and
is tracked as a follow-up. To deploy manually for evaluation:

```bash
# from the repo root
cd azure-function
func azure functionapp publish <function-app-name>
```

Local dev: copy `local.settings.json.template` to `local.settings.json`,
fill in values, then `func start`.
