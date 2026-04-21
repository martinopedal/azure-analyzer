# Continuous Control Function App (#165)

When the scheduled GitHub Actions workflow (`.github/workflows/scheduled-scan.yml`) and / or the `azure-function/` PowerShell Function App is deployed, the following identities and roles are required.

## GitHub Actions OIDC federation

The workflow signs in via OpenID Connect (no PATs, no client secrets). One-time setup:

1. Create (or reuse) an app registration / user-assigned managed identity in Entra ID.
2. Add a **federated credential** with subject claim:
   - `repo:<owner>/<repo>:ref:refs/heads/main` (for scheduled runs on main)
   - `repo:<owner>/<repo>:environment:production` (optional, if you gate via an environment)
3. Assign the identity **Reader** at the target subscription or management-group scope.
4. Set the repo variables `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`.

| Capability | Scope | Role | Why |
|---|---|---|---|
| Workflow OIDC sign-in | Subscription / MG | **Reader** | Drives the orchestrator's read-only collectors |
| (Optional) Log Analytics sink call | DCR | **Monitoring Metrics Publisher** | Same DCR write contract as the standalone sink |

## Azure Function App managed identity

The Function App runs `Invoke-AzureAnalyzer.ps1` under its own managed identity (system- or user-assigned). Roles:

| Capability | Scope | Role | Why |
|---|---|---|---|
| Function MI | Subscription / MG | **Reader** | Required for every Azure-scope collector |
| (Optional) Log Analytics sink | DCR | **Monitoring Metrics Publisher** | Only when `DCE_ENDPOINT` + `DCR_IMMUTABLE_ID` app settings are configured |
| (Optional) Future blob persistence | Storage account / container | **Storage Blob Data Contributor** | Reserved for future durable artifact storage |

The HTTP trigger uses `authLevel: function` (per-function key). Treat it as a **break-glass** on-demand path; the timer trigger is the primary contract.

## Bicep deployment - deployer permissions

The Bicep template at `infra/continuous-control.bicep` creates a Reader role assignment at subscription scope for the user-assigned MI. The identity that runs `az deployment group create` must have **Owner** or **User Access Administrator** at the target subscription. At runtime the MI is read-only - no additional write permissions are granted to the Function App beyond those listed above. The `deployLogAnalytics = true` path also grants **Monitoring Metrics Publisher** on the DCR to the MI; no other write roles are created.

## Optional Log Analytics sink

When `-SinkLogAnalytics` is enabled (whether from a workflow, the Function App, or an interactive run), the identity used by `Get-AzAccessToken` must have write permission on the target DCR:

| Capability | Scope | Role | Why |
|---|---|---|---|
| **Log Analytics sink (Logs Ingestion API)** | Data Collection Rule (DCR) | **Monitoring Metrics Publisher** | Required to POST findings / entities to DCR streams via `https://monitor.azure.com` token audience |

This is the only optional **write** permission anywhere in the project.
