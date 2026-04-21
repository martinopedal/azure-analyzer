# Cross-tool permission summary

This page aggregates the per-tool detail pages into a single matrix and documents the least-privilege model.

## Permission matrix (quick reference)

| Tool | Azure Reader | Microsoft Graph | GitHub Token | ADO PAT | Local CLI | Copilot License |
|------|-------------|-----------------|-------------|---------|-----------|-----------------|
| **azqr** | Required | -- | -- | -- | -- | -- |
| **PSRule** | Required | -- | -- | -- | -- | -- |
| **AzGovViz** | Required | -- | -- | -- | -- | -- |
| **ALZ Queries** | Required | -- | -- | -- | -- | -- |
| **WARA** | Required | -- | -- | -- | -- | -- |
| **Azure Cost** | Required (Consumption API read) | -- | -- | -- | -- | -- |
| **Defender for Cloud** | Required (`Microsoft.Security` read) | -- | -- | -- | -- | -- |
| **Sentinel Incidents** | Required (Log Analytics Reader on workspace) | -- | -- | -- | -- | -- |
| **Sentinel Coverage** | Required (Microsoft Sentinel Reader + Log Analytics Reader) | -- | -- | -- | -- | -- |
| **kubescape** | Reader (ARG AKS discovery) + AKS cluster-read RBAC (or kubeconfig) | -- | -- | -- | `kubescape`, `kubectl`, `az` | -- |
| **falco** | Reader (ARG + `Microsoft.Security` alert query); install mode also needs AKS cluster-read RBAC | -- | -- | -- | Optional install mode: `helm`, `kubectl`, `az` | -- |
| **kube-bench** | Reader (ARG AKS discovery) + AKS RBAC Admin (create/delete Job in `kube-system`) | -- | -- | -- | `kubectl`, `az` | -- |
| **Maester** | -- | Required | -- | -- | -- | -- |
| **Scorecard** | -- | -- | Recommended | -- | -- | -- |
| **ADO Connections** | -- | -- | -- | Required | -- | -- |
| **ADO Pipeline Security** | -- | -- | -- | Required | -- | -- |
| **ADO Repo Secrets** | -- | -- | -- | Required (`Code:Read`, `Project:Read`) | -- | -- |
| **ADO Pipeline Correlator** | -- | -- | -- | Required (`Build:Read`, `Project:Read`) | -- | -- |
| **zizmor** | -- | -- | Remote-only (PAT) | -- | Local fallback | -- |
| **gitleaks** | -- | -- | Remote-only (PAT) | -- | Local fallback | -- |
| **Trivy** | -- | -- | Remote-only (PAT) | -- | Local fallback | -- |
| **bicep-iac** | -- | -- | Remote (clone) | -- | Local fallback (`bicep`) | -- |
| **terraform-iac** | -- | -- | Remote (clone) | -- | Local fallback (`terraform` / `trivy`) | -- |
| **Identity Correlator** | Inherited | Optional (Graph lookup) | -- | -- | -- | -- |
| **Identity Graph Expansion** | Inherited | Optional (`User.Read.All`, `Application.Read.All`, `Directory.Read.All` for live mode) | -- | -- | -- | -- |
| **AI Triage** (opt-in) | -- | -- | Recommended | -- | -- | Optional license |

Legend: **Required** = tool will not function without it. **Recommended** = improves rate limits or feature completeness. **Optional** = additional capability the tool can use when present. **--** = not used.

## Permission tiers (v3)

Azure Analyzer v3 groups capabilities into permission tiers (Tier 0 to Tier 6) covering Azure, Graph, CI/CD, cost, and optional AI access. See [docs/contributor/ARCHITECTURE.md](../../contributor/ARCHITECTURE.md#permission-tiers-tier-06) for the tier breakdown.

## Least-privilege principle

Azure-analyzer follows the principle of least privilege:

1. **Read-only everywhere.** No write permissions on any scope (Azure, Graph, GitHub, ADO). The only exception is the optional Log Analytics sink, which requires `Monitoring Metrics Publisher` on the target DCR.
2. **Scoped to subscriptions / tenants.** Not broader than necessary.
3. **Graceful degradation.** Missing permissions do not fail the run; the affected tool is skipped with a warning.
4. **Tool-specific controls.** Use `-IncludeTools` or `-ExcludeTools` to run only what you have access to.

### Run only tools you have permissions for

```powershell
# If you don't have Microsoft Graph permissions, just run Azure tools
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -ExcludeTools 'maester'

# Or explicitly include only what you need
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -IncludeTools 'azqr','psrule'
```

## What we do NOT need

- **Contributor** or **Owner** roles. Reader is sufficient.
- **Write permissions** to any Azure resource (except the optional DCR sink role).
- **Key Vault access.** No secrets are read from or stored in Key Vault.
- **Network permissions.** No virtual network or firewall rules are modified.
- **Azure DevOps write permissions.** ADO collectors require only read access to metadata.
- **Service Principal Password.** Only object ID is needed for role assignment.

### AI Triage credentials (optional)

| Credential | Purpose |
|---|---|
| `COPILOT_GITHUB_TOKEN` / `GH_TOKEN` / `GITHUB_TOKEN` | Sends non-compliant finding data to GitHub Copilot API for AI-assisted triage. Only used when `-EnableAiTriage` is set. `ghs_` tokens are not supported. See [`docs/consumer/ai-triage.md`](../ai-triage.md). |
