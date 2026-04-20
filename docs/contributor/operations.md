# Operations runbook

Operator-focused reference for running, scheduling, and troubleshooting azure-analyzer in unattended environments. For consumer-focused setup walkthroughs see [`docs/consumer/`](../consumer/README.md).

## Shared infrastructure (reuse, do not reinvent)

Before adding retry, clone, sanitize, or install logic, check these modules first.

| Module | Purpose |
|---|---|
| [`tools/tool-manifest.json`](../../tools/tool-manifest.json) | Single source of truth for tool registration. New tools register here and the report and installer pick them up automatically. |
| [`modules/shared/Installer.ps1`](../../modules/shared/Installer.ps1) | Manifest-driven prerequisite installer. Handles `psmodule`, `cli`, `gitclone`, `none`. |
| [`modules/shared/RemoteClone.ps1`](../../modules/shared/RemoteClone.ps1) | HTTPS-only clone helper with host allow-list and post-clone token scrub. |
| [`modules/shared/Retry.ps1`](../../modules/shared/Retry.ps1) | `Invoke-WithRetry` with jittered backoff for transient failures. |
| [`modules/shared/Sanitize.ps1`](../../modules/shared/Sanitize.ps1) | `Remove-Credentials` for any output written to disk. |
| [`modules/shared/Schema.ps1`](../../modules/shared/Schema.ps1) | `New-FindingRow` is the only sanctioned way to emit v2 FindingRow entries. |
| [`modules/shared/EntityStore.ps1`](../../modules/shared/EntityStore.ps1) | v3 entity-centric store: findings + entities written separately. |

## Security invariants

These rules apply to every wrapper, normalizer, and installer change.

- HTTPS-only for any outbound URL. HTTP is rejected.
- Host allow-list for clone or fetch: `github.com`, `dev.azure.com`, `*.visualstudio.com`, `*.ghe.com`. Enforced by `RemoteClone.ps1`.
- Allow-listed package managers only: `winget`, `brew`, `pipx`, `pip`, `snap`. Enforced by `Installer.ps1`.
- Package-name regex prevents shell-injection via manifest-sourced package names.
- 300s timeout on every external process launch (`Invoke-WithTimeout`).
- Token scrubbing from `.git/config` immediately post-clone.
- `Remove-Credentials` on every artifact written to JSON, HTML, MD, or log files.
- Errors are thrown via `New-InstallerError` / `New-FindingError` with `Category`, `Remediation`, and sanitized `Details`.

## Continuous control mode

Two unattended entrypoints wrap `Invoke-AzureAnalyzer.ps1` so the scanner runs on a schedule.

### Scheduled GitHub Actions workflow

`.github/workflows/scheduled-scan.yml` runs daily at `0 6 * * *` UTC (plus `workflow_dispatch`). It authenticates to Azure via OIDC federation (no PATs), uploads `results.json`, `entities.json`, and HTML / Markdown reports as workflow artifacts, then a separate `report` job (with `issues: write` only) opens or comments on a single deduped `auto:scheduled-scan` issue when new or escalated Critical-severity findings are detected.

The workflow uses diff-mode (`modules/shared/Get-NewCriticalFindings.ps1` + `Compare-EntitySnapshots`) to compare against the previous run's snapshot so only net-new or escalated Criticals trigger an issue. First-run mode (no previous artifact) treats all Criticals as new.

Required repo variables (configure once via `gh variable set`):

| Variable | Description |
|---|---|
| `AZURE_CLIENT_ID` | App registration / user-assigned MI client id with the federated credential |
| `AZURE_TENANT_ID` | Entra tenant id |
| `AZURE_SUBSCRIPTION_ID` | Default subscription scope |

### Azure Function (PowerShell)

`azure-function/` ships `TimerScan/` (NCRONTAB `0 0 6 * * *`) and `HttpScan/` (`authLevel: function`, break-glass on-demand). Both run via the Function App's managed identity. The shared entrypoint reuses the existing Log Analytics sink (`modules/sinks/Send-FindingsToLogAnalytics.ps1`); sink invocation is opt-in via `DCE_ENDPOINT` and `DCR_IMMUTABLE_ID` app settings.

**Consumption-plan timeout caveat.** Azure Functions on the Consumption plan have a hard 10-minute per-invocation cap. The Timer trigger therefore restricts itself to a small toolset (`azqr`, `psrule`). For a full daily sweep, deploy on the Premium plan or Container Apps. See [`azure-function/README.md`](../../azure-function/README.md) for the full architecture overview, and the consumer walkthrough at [`docs/consumer/continuous-control.md`](../consumer/continuous-control.md).

## Output sinks

Azure Analyzer can ship `results` and `entities` to Log Analytics or Sentinel custom tables using the Logs Ingestion API (DCR-based path). See [`docs/consumer/sinks/log-analytics.md`](../consumer/sinks/log-analytics.md) for DCR / table setup, app-settings wiring, and KQL examples.

## Multi-tenant fan-out

For MSP and large enterprise scenarios, `Invoke-AzureAnalyzer.ps1` accepts:

- `-TenantConfig <path-to-json>` with explicit per-tenant subscription lists and labels.
- `-Tenants @('<guid>', ...)` for a bare GUID array (uses the default subscription in each tenant context).

Per-tenant outputs land under `<OutputPath>/<tenantId>/[<subscriptionId>/]`. The aggregate roll-up is written to `<OutputPath>/multi-tenant-summary.json` and `multi-tenant-summary.html`. Fan-out is sequential (clean Az / Microsoft.Graph context per tenant via child `pwsh` processes); per-tenant failures are recorded with sanitized stderr and the scan continues. Overall exit code is non-zero when any tenant fails.

`-TenantConfig` and `-Tenants` are mutually exclusive with each other and with single-tenant `-TenantId` / `-SubscriptionId` / `-ManagementGroupId`.

## Tool catalog

The full list of registered tools, normalizers, install kinds, and upstream pins is generated from the manifest. See [`tool-catalog.md`](./tool-catalog.md). To regenerate:

```powershell
pwsh -File scripts/Generate-ToolCatalog.ps1
```

CI runs the generator with `-CheckOnly` and fails when the committed catalog is stale relative to `tools/tool-manifest.json`.
