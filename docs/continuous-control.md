# Continuous Control: 10-Minute Deployment Walkthrough

This guide wires up the two unattended entrypoints shipped in PR #193:

- **Scheduled GitHub Actions workflow** (`.github/workflows/scheduled-scan.yml`): runs daily via OIDC, uploads artifacts, opens a deduped issue on Critical findings.
- **Azure Function App** (`azure-function/`): timer + HTTP triggers under a managed identity, with an optional Log Analytics sink.

Work through the sections in order. Total time: approximately 10 minutes for a minimal setup, 20 minutes if you also wire the Log Analytics sink.

---

## Prerequisites

| Tool | Minimum version |
|---|---|
| Azure CLI (`az`) | 2.57 |
| Azure Functions Core Tools (`func`) | 4.x |
| PowerShell | 7.4 |
| `gh` CLI | 2.x |

You need **Owner** or **User Access Administrator** on the target subscription (to assign the Reader role to the app registration), and **Application Administrator** in Entra ID (to create the app registration and federated credential).

---

## 1. OIDC Federated-Credential Setup

The scheduled workflow authenticates to Azure via OpenID Connect. No client secrets or PATs are stored in the repository.

### 1.1 Create an App Registration

```bash
# Create the registration (note the appId in the output)
az ad app create --display-name "azure-analyzer-ci" --query appId -o tsv
```

Save the returned `appId` -- you will need it in step 1.3.

### 1.2 Create a Service Principal for the App

```bash
az ad sp create --id <appId>
```

### 1.3 Add Federated Credentials

Add a credential that trusts the `main` branch (for the daily cron trigger):

```bash
az ad app federated-credential create \
  --id <appId> \
  --parameters '{
    "name": "azure-analyzer-main",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:martinopedal/azure-analyzer:ref:refs/heads/main",
    "audiences": ["api://AzureADTokenExchange"]
  }'
```

Optionally add a second credential for a GitHub Actions **environment** named `production` (useful if you gate scheduled runs behind a required reviewer):

```bash
az ad app federated-credential create \
  --id <appId> \
  --parameters '{
    "name": "azure-analyzer-production-env",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:martinopedal/azure-analyzer:environment:production",
    "audiences": ["api://AzureADTokenExchange"]
  }'
```

### 1.4 Assign Reader Role

```bash
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
OBJECT_ID=$(az ad sp show --id <appId> --query id -o tsv)

az role assignment create \
  --assignee-object-id "$OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role Reader \
  --scope "/subscriptions/$SUBSCRIPTION_ID"
```

To scan an entire management group instead of a single subscription, replace `--scope` with `/providers/Microsoft.Management/managementGroups/<mg-id>`.

### 1.5 Set Repository Variables

```bash
TENANT_ID=$(az account show --query tenantId -o tsv)

gh variable set AZURE_CLIENT_ID   --body "<appId>"
gh variable set AZURE_TENANT_ID   --body "$TENANT_ID"
gh variable set AZURE_SUBSCRIPTION_ID --body "$SUBSCRIPTION_ID"
```

These are repository **variables** (not secrets). They are visible in plain text in the Actions UI, which is intentional; they are GUIDs with no elevated privileges beyond Reader.

The workflow validates all three at startup and fails fast if any is missing or not a valid GUID.

---

## 2. Function App Deployment

The `azure-function/` directory is a self-contained PowerShell Function App. It ships two triggers:

- `TimerScan/` -- NCRONTAB `0 0 6 * * *` (06:00 UTC daily)
- `HttpScan/` -- `authLevel: function` (per-function key, break-glass on-demand)

Both route through `azure-function/Shared/Invoke-FunctionScan.ps1`.

### 2.1 Create the Function App in Azure

```bash
RESOURCE_GROUP="rg-azure-analyzer"
STORAGE_ACCOUNT="stazanalyzer$(openssl rand -hex 4)"  # must be globally unique
FUNCTION_APP_NAME="func-azure-analyzer"
LOCATION="eastus"

az group create --name "$RESOURCE_GROUP" --location "$LOCATION"

az storage account create \
  --name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku Standard_LRS

az functionapp create \
  --name "$FUNCTION_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --storage-account "$STORAGE_ACCOUNT" \
  --consumption-plan-location "$LOCATION" \
  --runtime powershell \
  --runtime-version 7.4 \
  --functions-version 4 \
  --assign-identity "[system]"
```

To use the Premium plan (recommended for full scans -- see [Section 5](#5-consumption-plan-timeout-and-alternatives)):

```bash
az functionapp plan create \
  --name "plan-azure-analyzer" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku EP1 \
  --is-linux false

az functionapp create \
  --name "$FUNCTION_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --storage-account "$STORAGE_ACCOUNT" \
  --plan "plan-azure-analyzer" \
  --runtime powershell \
  --runtime-version 7.4 \
  --functions-version 4 \
  --assign-identity "[system]"
```

### 2.2 Assign Reader to the Function App Managed Identity

```bash
FUNC_PRINCIPAL_ID=$(az functionapp identity show \
  --name "$FUNCTION_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query principalId -o tsv)

az role assignment create \
  --assignee-object-id "$FUNC_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role Reader \
  --scope "/subscriptions/$SUBSCRIPTION_ID"
```

### 2.3 Configure App Settings

```bash
az functionapp config appsettings set \
  --name "$FUNCTION_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --settings \
    "AZURE_ANALYZER_SUBSCRIPTION_ID=$SUBSCRIPTION_ID" \
    "AZURE_ANALYZER_TENANT_ID=$TENANT_ID" \
    "AZURE_ANALYZER_INCLUDE_TOOLS=azqr,psrule"
```

| Setting | Required | Notes |
|---|---|---|
| `AZURE_ANALYZER_SUBSCRIPTION_ID` | Yes (timer trigger) | Default subscription scope for the scan |
| `AZURE_ANALYZER_TENANT_ID` | Recommended | Used by the WARA collector |
| `AZURE_ANALYZER_INCLUDE_TOOLS` | Recommended | CSV of tool names; omit to run all (will exceed the 10-min Consumption cap) |
| `DCE_ENDPOINT` | Optional | Logs Ingestion DCE URL; sink is skipped when empty |
| `DCR_IMMUTABLE_ID` | Optional | DCR immutable ID paired with `DCE_ENDPOINT` |
| `FINDINGS_STREAM` | Optional | Stream name; defaults to `Custom-AzureAnalyzerFindings` |
| `ENTITIES_STREAM` | Optional | Stream name; defaults to `Custom-AzureAnalyzerEntities` |
| `SINK_DRY_RUN` | Optional | Set to `true` to write sink payload to disk instead of POSTing |

### 2.4 Publish the Function App

```bash
cd azure-function
func azure functionapp publish "$FUNCTION_APP_NAME"
```

Verify the timer is registered:

```bash
az functionapp function list \
  --name "$FUNCTION_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query "[].{name:name, trigger:config.bindings[0].type}" \
  -o table
```

You should see `TimerScan` (timerTrigger) and `HttpScan` (httpTrigger).

### 2.5 Test the HTTP Trigger (Break-glass)

```bash
FUNC_URL=$(az functionapp function show \
  --name "$FUNCTION_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --function-name HttpScan \
  --query invokeUrlTemplate -o tsv)

FUNC_KEY=$(az functionapp keys list \
  --name "$FUNCTION_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query functionKeys.default -o tsv)

curl -s -X POST "$FUNC_URL?code=$FUNC_KEY" \
  -H "Content-Type: application/json" \
  -d '{"subscriptionId":"<your-subscription-id>","includeTools":["azqr"]}'
```

The `includeTools` field is validated against a hard-coded allow-list (`azqr`, `psrule`, `alz-queries`, `wara`, `azure-cost`, `finops`, `defender-for-cloud`, `sentinel-incidents`, `sentinel-coverage`, `maester`, `identity-correlator`). Any unknown tool name causes a 400 response.

---

## 3. DCR / Sink Wiring (Optional)

When `DCE_ENDPOINT` and `DCR_IMMUTABLE_ID` are configured, both the scheduled workflow and the Function App forward `entities.json` to a Log Analytics custom table via the Logs Ingestion API. This is the same sink used by the standalone `Send-FindingsToLogAnalytics.ps1` module.

### 3.1 Create a Data Collection Endpoint

```bash
az monitor data-collection endpoint create \
  --name "dce-azure-analyzer" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --public-network-access Enabled \
  --query logsIngestion.endpoint -o tsv
```

Save the returned HTTPS endpoint URL.

### 3.2 Create a Data Collection Rule

First, create the DCR definition file `dcr-definition.json`:

```json
{
  "location": "eastus",
  "kind": "Direct",
  "properties": {
    "dataCollectionEndpointId": "/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<RESOURCE_GROUP>/providers/Microsoft.Insights/dataCollectionEndpoints/dce-azure-analyzer",
    "streamDeclarations": {
      "Custom-AzureAnalyzerFindings": {
        "columns": [
          { "name": "TimeGenerated", "type": "datetime" },
          { "name": "FindingId",     "type": "string" },
          { "name": "RuleId",        "type": "string" },
          { "name": "Severity",      "type": "string" },
          { "name": "EntityId",      "type": "string" },
          { "name": "EntityType",    "type": "string" },
          { "name": "Platform",      "type": "string" },
          { "name": "Title",         "type": "string" },
          { "name": "Compliant",     "type": "boolean" }
        ]
      },
      "Custom-AzureAnalyzerEntities": {
        "columns": [
          { "name": "TimeGenerated", "type": "datetime" },
          { "name": "EntityId",      "type": "string" },
          { "name": "EntityType",    "type": "string" },
          { "name": "Platform",      "type": "string" },
          { "name": "ObservationCount", "type": "int" }
        ]
      }
    },
    "destinations": {
      "logAnalytics": [
        {
          "workspaceResourceId": "/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<RESOURCE_GROUP>/providers/Microsoft.OperationalInsights/workspaces/<WORKSPACE_NAME>",
          "name": "la-destination"
        }
      ]
    },
    "dataFlows": [
      {
        "streams": ["Custom-AzureAnalyzerFindings", "Custom-AzureAnalyzerEntities"],
        "destinations": ["la-destination"],
        "outputStream": "Custom-AzureAnalyzerFindings_CL"
      }
    ]
  }
}
```

```bash
az monitor data-collection rule create \
  --name "dcr-azure-analyzer" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --rule-file dcr-definition.json \
  --query immutableId -o tsv
```

Save the returned immutable ID (format: `dcr-<hex>`).

### 3.3 Assign Monitoring Metrics Publisher to the Function App MI

```bash
DCR_RESOURCE_ID=$(az monitor data-collection rule show \
  --name "dcr-azure-analyzer" \
  --resource-group "$RESOURCE_GROUP" \
  --query id -o tsv)

az role assignment create \
  --assignee-object-id "$FUNC_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Monitoring Metrics Publisher" \
  --scope "$DCR_RESOURCE_ID"
```

For the scheduled GitHub Actions workflow, assign the same role to the app registration's service principal:

```bash
az role assignment create \
  --assignee-object-id "$OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Monitoring Metrics Publisher" \
  --scope "$DCR_RESOURCE_ID"
```

### 3.4 Wire the Settings

```bash
DCE_ENDPOINT="<https endpoint from step 3.1>"
DCR_IMMUTABLE_ID="<immutable id from step 3.2>"

# Function App
az functionapp config appsettings set \
  --name "$FUNCTION_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --settings \
    "DCE_ENDPOINT=$DCE_ENDPOINT" \
    "DCR_IMMUTABLE_ID=$DCR_IMMUTABLE_ID"

# Scheduled workflow (via repo variables)
gh variable set DCE_ENDPOINT    --body "$DCE_ENDPOINT"
gh variable set DCR_IMMUTABLE_ID --body "$DCR_IMMUTABLE_ID"
```

The sink is opt-in: if either variable is absent or empty, the upload step is silently skipped and the scan still completes successfully.

See [docs/sinks/log-analytics.md](sinks/log-analytics.md) for DCR table setup and KQL query examples.

---

## 4. Failure Modes: Consumption-Plan Timeout

Azure Functions on the **Consumption plan** enforce a hard **10-minute per-invocation cap**. A full azure-analyzer scan across all tools typically exceeds this limit.

### Default behaviour

The `TimerScan/` trigger defaults to `AZURE_ANALYZER_INCLUDE_TOOLS=azqr,psrule` to stay well under 10 minutes. The HTTP trigger also validates against the allow-list and applies the same bounded toolset unless an explicit `includeTools` override is provided.

### Symptoms of a timeout

- Function execution logs show `Function execution failed` with reason `Timeout`.
- `entities.json` is absent or incomplete in the artifact output.
- Sink forwarding never fires (it runs after the scan completes).

### Recommendations

| Plan | Max duration | Recommendation |
|---|---|---|
| Consumption (Y1) | 10 min | Use only `azqr,psrule` or `azqr,psrule,alz-queries` |
| Premium (EP1/EP2/EP3) | 60 min (configurable to unlimited) | Supports full toolset daily scan |
| Container Apps | No enforced timeout | Recommended for long scans; add `--max-replicas 1` to prevent parallel runs |

### Migrating to Premium

```bash
# Create a Premium plan
az functionapp plan create \
  --name "plan-azure-analyzer-premium" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku EP1 \
  --is-linux false

# Move the existing Function App to the Premium plan
az functionapp update \
  --name "$FUNCTION_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --plan "plan-azure-analyzer-premium"

# Expand the toolset now that time is not a constraint
az functionapp config appsettings set \
  --name "$FUNCTION_APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --settings \
    "AZURE_ANALYZER_INCLUDE_TOOLS=azqr,psrule,alz-queries,wara,finops,defender-for-cloud"
```

On Premium and Container Apps, leave `AZURE_ANALYZER_INCLUDE_TOOLS` unset to run the full tool profile on every invocation.

---

## 5. Scheduling

### Scheduled GitHub Actions workflow

The cron expression lives in `.github/workflows/scheduled-scan.yml`:

```yaml
on:
  schedule:
    - cron: '0 6 * * *'   # 06:00 UTC daily
```

To change the schedule, edit the cron string using standard POSIX cron syntax (five fields: minute, hour, day-of-month, month, day-of-week). GitHub Actions uses UTC.

Common schedules:

| Schedule | Cron |
|---|---|
| Daily at 02:00 UTC | `0 2 * * *` |
| Weekdays at 06:00 UTC | `0 6 * * 1-5` |
| Every 6 hours | `0 */6 * * *` |
| Weekly on Mondays at 07:00 UTC | `0 7 * * 1` |

After editing, commit and push. The new schedule is picked up immediately on the next cron tick. Use the `workflow_dispatch` trigger to test on demand without waiting:

```bash
gh workflow run scheduled-scan.yml \
  --field include_tools=azqr \
  --field subscription_id="$SUBSCRIPTION_ID"
```

### Azure Function timer trigger

The timer expression lives in `azure-function/TimerScan/function.json`:

```json
{
  "bindings": [
    {
      "type": "timerTrigger",
      "schedule": "0 0 6 * * *"
    }
  ]
}
```

This is NCRONTAB format (six fields: second, minute, hour, day-of-month, month, day-of-week). After editing, republish with `func azure functionapp publish <function-app-name>`.

To run the timer trigger immediately without waiting:

```bash
az rest --method post \
  --uri "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Web/sites/$FUNCTION_APP_NAME/functions/TimerScan/listtriggers?api-version=2022-03-01"
```

---

## Verification Checklist

After completing the above steps, confirm:

- [ ] `gh variable list` shows `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`
- [ ] `az role assignment list --assignee <appId> --scope /subscriptions/<id>` shows **Reader**
- [ ] `gh workflow run scheduled-scan.yml --field include_tools=azqr` completes green
- [ ] Function App `TimerScan` appears in Azure portal under the Function App
- [ ] `curl` test of `HttpScan` returns a 200 with a JSON body
- [ ] (Optional) Log Analytics workspace shows rows in `Custom-AzureAnalyzerFindings_CL` after a scan

---

## Related Documentation

- [azure-function/README.md](../azure-function/README.md) -- Function App architecture overview and app settings reference
- [PERMISSIONS.md](../PERMISSIONS.md#continuous-control-function-app-165) -- full RBAC breakdown
- [docs/sinks/log-analytics.md](sinks/log-analytics.md) -- DCR/table setup and KQL examples
