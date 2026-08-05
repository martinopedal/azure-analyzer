# Azure DevOps auth for the ADO wrappers

azure-analyzer's five Azure DevOps wrappers (`ado-pipelines`, `ado-connections`, `ado-repos-secrets`, `ado-consumption`, `ado-pipeline-correlator`) authenticate to the Azure DevOps REST API with an HTTP Basic header. That header accepts **either** a classic personal access token (PAT) **or** a Microsoft Entra access token issued for the Azure DevOps resource.

The Entra path matters in tenants where PAT creation is disabled by policy. Without it, ADO scanning cannot run at all in those tenants.

Closes [#1226](https://github.com/martinopedal/azure-analyzer/issues/1226).

## How the credential is resolved

All five wrappers resolve the credential through the same `Resolve-AdoPat` helper, in this order:

1. `-AdoPat` (explicit parameter; all five wrappers also accept the `-AdoPatToken` alias)
2. `$env:ADO_PAT_TOKEN`
3. `$env:AZURE_DEVOPS_EXT_PAT`
4. `$env:AZ_DEVOPS_PAT`

The resolved value is used as the **password** in a Basic header with an empty username:

```powershell
$pair = ":$pat"
$headers = @{ Authorization = "Basic $([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair)))" }
```

Azure DevOps accepts an Entra access token in that password slot, so no separate code path or parameter is needed. Anywhere this documentation says "PAT", an Entra access token works identically.

## Option 1: classic PAT

Create a PAT in Azure DevOps (**User settings -> Personal access tokens**) with the read scopes listed on the per-tool pages under [`docs/reference/permissions/`](../reference/permissions/README.md), then:

```powershell
$env:ADO_PAT_TOKEN = '<pat>'
./Invoke-AzureAnalyzer.ps1 -AdoOrg 'https://dev.azure.com/contoso' -IncludeTools ado-pipelines
```

## Option 2: Entra access token (no PAT required)

Acquire a token for the Azure DevOps resource `499b84ac-1321-427f-aa17-267ca6975798`. This GUID is the fixed, Microsoft-assigned application ID for Azure DevOps and is the same in every tenant.

```powershell
$env:ADO_PAT_TOKEN = az account get-access-token `
    --resource 499b84ac-1321-427f-aa17-267ca6975798 `
    --query accessToken -o tsv

./Invoke-AzureAnalyzer.ps1 -AdoOrg 'https://dev.azure.com/contoso' -IncludeTools ado-pipelines
```

Bash equivalent:

```bash
export ADO_PAT_TOKEN="$(az account get-access-token \
  --resource 499b84ac-1321-427f-aa17-267ca6975798 \
  --query accessToken -o tsv)"
```

Any credential that yields a token for that resource works, including `Get-AzAccessToken` and a federated / workload-identity credential in CI:

```powershell
$env:ADO_PAT_TOKEN = (Get-AzAccessToken -ResourceUrl '499b84ac-1321-427f-aa17-267ca6975798').Token
```

### Lifetime

This is the main practical difference. An Entra access token is typically valid for about **one hour**, where a PAT can last months. Consequences:

- Acquire the token immediately before the scan, not in an earlier pipeline stage.
- For long scans across many projects, prefer a PAT if your tenant allows one; a token that expires mid-scan surfaces as `401 Unauthorized` partway through.
- Do not cache the token between runs.

### Permissions

The identity behind the token needs the same Azure DevOps read access a PAT would need for the equivalent scopes; see the per-tool pages under [`docs/reference/permissions/`](../reference/permissions/README.md). Using an Entra token does not grant anything a PAT could not, and adds no new Azure, Microsoft Graph, or GitHub scopes.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `Status = Skipped`, message `No ADO PAT provided. Set -AdoPat/-AdoPatToken, ADO_PAT_TOKEN, AZURE_DEVOPS_EXT_PAT, or AZ_DEVOPS_PAT.` | None of the four sources above is set. |
| `401 Unauthorized` immediately | Token issued for the wrong resource. It must be `499b84ac-1321-427f-aa17-267ca6975798`, not Microsoft Graph or ARM. |
| `401 Unauthorized` partway through a long scan | Entra token expired mid-run. Re-acquire immediately before the scan, or use a PAT. |
| `203 Non-Authoritative Information` / an HTML sign-in page | Azure DevOps redirected to interactive sign-in, which usually means the credential was not accepted at all. Re-check the resource GUID. |

## Security notes

- Never commit a PAT or token. Pass it through an environment variable or a secret store.
- azure-analyzer routes tool output through `Remove-Credentials` before anything is written to `results.json`, `errors.json`, or the HTML/MD reports, so tokens are scrubbed from report artifacts.
- Prefer the Entra path in CI where a federated credential is available: it removes the long-lived secret entirely.
