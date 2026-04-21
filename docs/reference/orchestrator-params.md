# Invoke-AzureAnalyzer Parameters

Complete reference for all parameters to `Invoke-AzureAnalyzer.ps1`. See your scenario below for the most common parameters.

## Scan Target (pick one)

Exactly one of these is required:

- `-SubscriptionId <guid>` — Azure subscription ID to scan (most common).
- `-ManagementGroupId <guid>` — Azure management group to recursively scan (includes all subscriptions).
- `-TenantId <guid>` — Entire tenant scan. Requires very high permissions; usually management group is sufficient.
- `-Repository <string>` — Remote GitHub or Azure DevOps repo URL (e.g., `github.com/org/repo` or `dev.azure.com/org/proj/_git/repo`).
- `-SentinelWorkspaceId <guid>` — Azure Sentinel workspace ID for incident scanning.

## Common Parameters (Visible by Default)

- **`-IncludeTools <string[]>`** — Which tools to run. Default: all enabled tools. Example: `-IncludeTools 'azqr','psrule','gitleaks'`.
- **`-OutputPath <string>`** — Where to write results. Default: `./output`. Example: `-OutputPath ./findings`.
- **`-Severity <string[]>`** — Filter findings by severity before report. Options: `Critical`, `High`, `Medium`, `Low`, `Info`. Default: show all.
- **`-InstallMissingModules`** — Auto-install missing prerequisites (PSGallery modules, CLI tools). Default: `$false`.

**Common invocation**:
```powershell
Invoke-AzureAnalyzer -SubscriptionId "<id>" -IncludeTools 'azqr','psrule' -OutputPath ./results
```

---

<details open><summary><b>Advanced Parameters</b></summary>

- **`-ProxyUrl <string>`** — HTTP proxy for external API calls (optional).
- **`-ProxyCredential <pscredential>`** — Proxy authentication credentials (optional).
- **`-KubeContext <string>`** — Kubernetes context for kubescape, kube-bench, falco (optional).
- **`-KubeNamespace <string>`** — Kubernetes namespace to scan (optional, default: all).
- **`-SinkLogAnalytics`** — Stream findings to Azure Log Analytics (optional). Requires `-LogAnalyticsWorkspaceId` and `-LogAnalyticsDcrId`.
- **`-LogAnalyticsWorkspaceId <guid>`** — Log Analytics workspace ID for sinking (optional).
- **`-LogAnalyticsDcrId <string>`** — Data Collection Rule resource ID for Log Analytics (optional).
- **`-CustomSchema <hashtable>`** — Override Schema 2.2 defaults for custom normalizers (advanced, optional).
- **`-EnableAiTriage`** — Enable AI-assisted finding summaries (optional, requires Copilot or Azure OpenAI endpoint).
- **`-SkipDependencyCheck`** — Skip prerequisite checks and attempt tool invocation anyway (dangerous, optional).

</details>

---

<details><summary><b>Parameter Grouping by Scenario</b></summary>

### Scenario: Subscription Scan (Most Common)

```powershell
Invoke-AzureAnalyzer `
  -SubscriptionId "<subscription-id>" `
  -IncludeTools 'azqr','psrule','azbctest' `
  -OutputPath ./results `
  -InstallMissingModules
```

### Scenario: Management Group Scan (Multi-Subscription)

```powershell
Invoke-AzureAnalyzer `
  -ManagementGroupId "<management-group-id>" `
  -IncludeTools 'azqr' `
  -OutputPath ./org-audit
```

### Scenario: GitHub Repository Scan

```powershell
$env:GITHUB_AUTH_TOKEN = "<pat-token>"
Invoke-AzureAnalyzer `
  -Repository "github.com/org/repo" `
  -IncludeTools 'gitleaks','scorecard','trivy','zizmor' `
  -OutputPath ./repo-findings
```

### Scenario: Azure DevOps Repository Scan

```powershell
$env:AZURE_DEVOPS_PAT = "<ado-pat>"
Invoke-AzureAnalyzer `
  -Repository "dev.azure.com/org/project/_git/repo" `
  -IncludeTools 'ado-repos-secrets','ado-pipelines' `
  -OutputPath ./ado-findings
```

### Scenario: Kubernetes Cluster Scan

```powershell
Invoke-AzureAnalyzer `
  -SubscriptionId "<subscription-id>" `
  -IncludeTools 'kubescape','kube-bench','falco' `
  -KubeContext "my-aks-context" `
  -KubeNamespace "default" `
  -OutputPath ./aks-findings
```

### Scenario: Continuous Control (Scheduled)

```powershell
# In an Azure Function App or GitHub Actions
Invoke-AzureAnalyzer `
  -SubscriptionId "<subscription-id>" `
  -SinkLogAnalytics `
  -LogAnalyticsWorkspaceId "<workspace-id>" `
  -LogAnalyticsDcrId "<dcr-resource-id>" `
  -Severity 'Critical','High'
```

### Scenario: AI-Assisted Triage

```powershell
Invoke-AzureAnalyzer `
  -SubscriptionId "<subscription-id>" `
  -OutputPath ./results `
  -EnableAiTriage
```

</details>

---

## Environment Variables

Some tools require environment variables for authentication:

| Variable | Used by | Example |
|----------|---------|---------|
| `GITHUB_AUTH_TOKEN` | gitleaks, Scorecard, Trivy (remote) | `$env:GITHUB_AUTH_TOKEN = "<pat>"` |
| `AZURE_DEVOPS_PAT` | ADO tools | `$env:AZURE_DEVOPS_PAT = "<pat>"` |
| `KUBECONFIG` | kubescape, kube-bench, falco | `$env:KUBECONFIG = "~/.kube/config"` |

---

## Output Files

After a run, check the output directory for:

- **`results.json`** — Raw findings in v1 schema (legacy format).
- **`entities.json`** — Deduplicated entities in v3 format (new).
- **`report.html`** — Interactive findings browser.
- **`report.md`** — Markdown findings for Git workflows.
- **Tool-specific subdirectories** — Raw tool output (in `output/` subdirectory, typically for auditing).

---

## Full Reference

See [docs/reference/etl-pipeline.md](etl-pipeline.md) for the data flow from raw tool output through normalization and entity deduplication. See [docs/reference/schema-2.2.md](schema-2.2.md) for the complete Schema 2.2 FindingRow specification.
