# Permissions Reference -- azure-analyzer

## Core Principle

Azure-analyzer remains read-first for assessment collection, and now has one optional write path: Log Analytics sink ingestion. Azure-analyzer uses only the minimum permissions required for each enabled capability.

Phase 0 v3 core modules (Schema, Canonicalize, EntityStore, tool manifest) introduce no new permissions or scopes.

---

## New permission requirement (optional sink)

When `-SinkLogAnalytics` is enabled, the identity used by `Get-AzAccessToken` must have write permission on the target DCR:

| Capability | Scope | Role | Why |
|------|-------|------|-----|
| **Log Analytics sink (Logs Ingestion API)** | Data Collection Rule (DCR) | **Monitoring Metrics Publisher** | Required to POST findings/entities to DCR streams via `https://monitor.azure.com` token audience |

This is the first optional write permission in the project. Reader baseline requirements remain unchanged for all read collectors.

---

## Continuous Control Function App (#165)

When the scheduled GitHub Actions workflow (`.github/workflows/scheduled-scan.yml`) and/or the `azure-function/` PowerShell Function App is deployed, the following identities and roles are required.

### GitHub Actions OIDC federation

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
| (Optional) Log Analytics sink call | DCR | **Monitoring Metrics Publisher** | Same DCR write contract as the standalone sink (see above) |

### Azure Function App managed identity

The Function App runs `Invoke-AzureAnalyzer.ps1` under its own managed identity (system- or user-assigned). Roles:

| Capability | Scope | Role | Why |
|---|---|---|---|
| Function MI | Subscription / MG | **Reader** | Required for every Azure-scope collector |
| (Optional) Log Analytics sink | DCR | **Monitoring Metrics Publisher** | Only when `DCE_ENDPOINT` + `DCR_IMMUTABLE_ID` app settings are configured |
| (Optional) Future blob persistence | Storage account / container | **Storage Blob Data Contributor** | Reserved for the deferred Bicep deployment follow-up that wires durable artifact storage |

The HTTP trigger uses `authLevel: function` (per-function key). Treat it as a **break-glass** on-demand path; the timer trigger is the primary contract.

---

## Permission tiers (v3)

Azure Analyzer v3 groups capabilities into permission tiers (Tier 0–6) covering
Azure, Graph, CI/CD, cost, and optional AI access. See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the tier breakdown.

---

## Required permissions by scope

### Azure (Reader -- all resource tools)

| Tool | Scope | Role | Why |
|------|-------|------|-----|
| **azqr** | Subscription | Reader | Scans resource configurations for compliance checks |
| **PSRule for Azure** | Subscription | Reader | Evaluates resources against rule-based policies |
| **AzGovViz** | Management Group | Reader | Crawls governance hierarchy, policies, and RBAC assignments |
| **ALZ Resource Graph queries** | Subscription or MG | Reader | Runs 132 custom ARG queries for Azure architecture assessment |
| **WARA** | Subscription | Reader | Collects Well-Architected Framework reliability assessment data |
| **FinOps Signals** | Subscription | Reader + Cost Management Reader | Correlates idle-resource ARG signals (including ungoverned snapshots >90d) with Cost Management monthly spend data |
| **kubescape** | Subscription | Reader + AKS cluster-read RBAC | Discovers AKS via ARG and runs in-cluster runtime posture scans through kubeconfig access |
| **falco** | Subscription | Reader (query mode) + optional AKS cluster-read RBAC for install mode | Reads Falco runtime alerts already present in Azure; optional install mode deploys Falco to AKS for short-lived runtime capture |
| **kube-bench** | Subscription | Reader + AKS RBAC Admin | Discovers AKS via ARG, applies a temporary kube-bench Job in `kube-system`, then collects node-level CIS results |

### Repository-scoped IaC validation (no Azure permissions)

| Tool | Scope | Role | Why |
|------|-------|------|-----|
| **Bicep IaC Validation** | Local repository | None | Runs `bicep build` against .bicep files in a cloned repo; no Azure API calls |
| **Terraform IaC Validation** | Local repository | None | Runs `terraform validate` and `trivy config` against .tf files; no Azure API calls |

These tools operate entirely on local IaC files (cloned via `RemoteClone.ps1` or provided via `-RepoPath`). They require no Azure, Graph, or GitHub API permissions. The only prerequisites are the CLI tools themselves (bicep, terraform, trivy).

**How to grant:**
```powershell
# Option 1: Azure CLI
az role assignment create \
  --assignee <principal-id-or-email> \
  --role Reader \
  --scope /subscriptions/<subscription-id>

# Option 2: PowerShell
New-AzRoleAssignment `
  -ObjectId <principal-id> `
  -RoleDefinitionName Reader `
  -Scope "/subscriptions/<subscription-id>"
```

**Where to find IDs:**
- **Object ID (service principal):** `az ad sp show --id <app-id> --query id`
- **Object ID (user):** `az ad user show --id <email> --query id`
- **Subscription ID:** `az account show --query id`

---

### Management group recursion

When you provide `-ManagementGroupId`, azure-analyzer automatically discovers all child subscriptions and tailors tool execution based on scope:

| Tool scope | Behavior |
|------------|----------|
| **Subscription-scoped** (azqr, PSRule, WARA) | Runs **per discovered subscription** |
| **MG-scoped** (AzGovViz, ALZ Queries) | Runs **once at the MG level** |
| **Tenant-scoped** (Maester) | Runs **once for the entire tenant** |
| **Workspace-scoped** (Sentinel Incidents) | Runs when `-SentinelWorkspaceId` is provided |
| **Repo-scoped** (Scorecard) | Independent of Azure hierarchy; runs for specified repo only |
| **CLI-scoped** (zizmor, gitleaks, Trivy) | Local filesystem tools; run automatically, no cloud scope needed |
| **ADO-scoped** (ADO Connections, ADO Pipeline Security, ADO Repo Secrets, ADO Pipeline Correlator) | Independent of Azure hierarchy; runs when `-AdoOrg` is provided |

**Required permissions for recursion:**
- `Reader` on the management group (auto-inherited to all child subscriptions)
- **OR** `Reader` on each individual subscription (if you lack MG-level permissions)

**Discovery behavior:**
- **Tenant root group:** Include all subscriptions in the tenant
- **Specific MG:** Include only the MG and its direct children (recursive)
- **No recursion:** Use `-Recurse:$false` to scan only the specified MG, without discovering child subscriptions

**Portfolio rollup note:**
- The portfolio heatmap and management-group breadcrumb perform one extra Azure Resource Graph read over the `subscriptions` entries in `resourcecontainers`, projecting `properties.managementGroupAncestorsChain` for management-group ancestry context.
- This is still covered by the same **Reader** role at the management-group scope. No new Azure role, no write action, and no role-assignment permission is required.

**Examples:**

```powershell
# Scan entire tenant from root MG
# Discovers all subscriptions; azqr/PSRule/WARA run per sub
.\Invoke-AzureAnalyzer.ps1 -ManagementGroupId "00000000-0000-0000-0000-000000000000"

# Scan specific MG subtree
# E.g., "my-landing-zone" -- discovers child subs, runs sub-tools per discovery
.\Invoke-AzureAnalyzer.ps1 -ManagementGroupId "my-landing-zone"

# MG-level tools only, skip per-subscription recursion
# AzGovViz and ALZ Queries run for "prod-mg"; azqr/PSRule/WARA skipped
.\Invoke-AzureAnalyzer.ps1 -ManagementGroupId "prod-mg" -Recurse:$false

# Combine MG recursion with tool filtering
# Scan entire MG tree, but only run Maester (Entra ID security)
.\Invoke-AzureAnalyzer.ps1 -ManagementGroupId "tenant-root" -IncludeTools 'maester'

# Scan MG tree for governance + reliability, skip compliance checks
.\Invoke-AzureAnalyzer.ps1 -ManagementGroupId "my-mg" -ExcludeTools 'azqr','psrule'
```

---

### Azure Cost (Consumption API -- 30-day spend)

The Azure Cost wrapper queries `Microsoft.Consumption/usageDetails` for a trailing 30-day window per subscription, aggregates spend per resource ID, and folds `MonthlyCost` / `Currency` onto existing AzureResource entities. No new role is required beyond subscription `Reader`, since the Consumption API authorizes off subscription-level read.

| Token / scope | Why |
|---------------|-----|
| **Reader** at subscription scope | Required for `Invoke-AzRestMethod` to call `Microsoft.Consumption/usageDetails` |
| (Optional) **Cost Management Reader** at subscription scope | Recommended for environments where tenant policy restricts Consumption data to the dedicated Cost role; functionally equivalent for this read path |

**Parameters:**

- `-SubscriptionId <guid>` (required, passed by orchestrator).
- `-TopN <int>` (default `20`): number of top costly resources emitted as findings (range 1..100).
- `-OutputPath <dir>` (optional): write raw API JSON for audit.

**Sample command:**

```powershell
# Single subscription
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "<sub-guid>" -IncludeTools 'azure-cost'

# Across an MG (per-subscription discovery applies; cost runs per child sub)
.\Invoke-AzureAnalyzer.ps1 -ManagementGroupId "<mg-id>" -IncludeTools 'azure-cost'
```

**What it scans:**

- 30-day usage records via `Microsoft.Consumption/usageDetails` (paged, up to 20 pages of 5,000 records).
- Subscription roll-up (total spend, billing currency).
- Top-N costly resources (resource ID, type, location, total cost).

**What it does NOT do:**

- No budget creation or modification.
- No resource modification (no scaling, deletion, tagging).
- No forecasting or anomaly alerting (point-in-time aggregation only).
- No cross-subscription rebilling or chargeback writes.
- Gracefully **skips** when the subscription has no Consumption data (new sub, trial, CSP without Consumption API access), typically as an empty result set (HTTP 200 with empty `value` array); HTTP 404 is treated as an access/scope/availability edge case.

---

### FinOps Signals (idle and unused resource detection)

The FinOps wrapper runs `queries/finops-*.json` against Azure Resource Graph and joins findings with monthly waste estimates from the Cost Management query API. This surfaces likely idle spend areas such as unattached disks, deallocated VMs, unused public IPs, idle App Service Plans, empty resource groups, and idle network controls.

| Token / scope | Why |
|---------------|-----|
| **Reader** at subscription scope | Required for `Search-AzGraph` over `resources` and `resourcecontainers` tables |
| **Cost Management Reader** at subscription scope | Required in restricted tenants for `Microsoft.CostManagement/query` |
| (Alternative) **Reader** at subscription scope | Sufficient in tenants where Reader can call Cost Management query read endpoints |

**API namespaces used:** `Microsoft.ResourceGraph/*` (read), `Microsoft.CostManagement/query` (read).

**Parameters:**

- `-SubscriptionId <guid>` (required, passed by orchestrator).
- `-OutputPath <dir>` (optional): write wrapper JSON output for audit.

**Sample command:**

```powershell
# Single subscription FinOps-only run
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "<sub-guid>" -IncludeTools 'finops'

# Across an MG (runs per discovered subscription)
.\Invoke-AzureAnalyzer.ps1 -ManagementGroupId "<mg-id>" -IncludeTools 'finops'
```

**What it does NOT do:**

- No resource mutations, deletions, stop/start actions, or tagging.
- No budget creation or alert policy changes.
- No rightsizing recommendations outside the curated idle-signal set.

---

### Microsoft Defender for Cloud (Secure Score + recommendations)

The Defender for Cloud wrapper reads two endpoints under `Microsoft.Security/*`: the subscription Secure Score (`secureScores/ascScore`) and non-healthy assessments (`assessments`, paged). The Secure Score lands on the Subscription entity; each non-healthy assessment lands on its target AzureResource so Defender recommendations fold next to existing azqr/PSRule findings on the same resource.

| Token / scope | Why |
|---------------|-----|
| **Security Reader** at subscription scope | Required to read `Microsoft.Security/secureScores` and `Microsoft.Security/assessments` |
| (Alternative) **Reader** at subscription scope | Sufficient in tenants where Reader is permitted to read `Microsoft.Security/*`; Security Reader is the documented least-privilege role |

**API namespace used:** `Microsoft.Security/*` (read).

**Parameters:**

- `-SubscriptionId <guid>` (required, passed by orchestrator).
- `-OutputPath <dir>` (optional): write raw API JSON for audit.

**Sample command:**

```powershell
# Single subscription
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "<sub-guid>" -IncludeTools 'defender-for-cloud'

# Across an MG (runs per child subscription)
.\Invoke-AzureAnalyzer.ps1 -ManagementGroupId "<mg-id>" -IncludeTools 'defender-for-cloud'
```

**What it scans:**

- Secure Score (current, max, percentage) for the subscription.
- Non-healthy assessments only (status `Unhealthy`); paged across up to 20 pages.
- Per-assessment metadata: display name, severity, description, remediation guidance, target resource ID.
- Regulatory compliance posture (surfaced indirectly via the assessment recommendations that map to compliance controls).

**What it does NOT do:**

- No remediation, no Quick Fix execution.
- No policy creation or modification (no `Microsoft.Authorization/policyAssignments` writes).
- No alert acknowledgment, dismissal, or rule changes.
- No Defender plan enable/disable on subscriptions.
- Gracefully **skips** when Defender for Cloud is not enabled on the subscription (HTTP 404/409 on `secureScores`).

---

### Microsoft Sentinel (Active Incidents via Log Analytics)

The Sentinel incidents wrapper queries the Log Analytics workspace API (`/api/query`) with KQL against the `SecurityIncident` table. It reads active (non-closed) incidents including severity, status, classification, owner, and linked alert counts. Incidents are scoped to the workspace ARM resource and fold into the EntityStore alongside Defender for Cloud findings.

| Token / scope | Why |
|---------------|-----|
| **Log Analytics Reader** on the workspace | Required to query the `SecurityIncident` table via the workspace query API |
| (Alternative) **Reader** on the workspace resource group | Sufficient in tenants where Reader permits `Microsoft.OperationalInsights/workspaces/api/query` |

**API endpoint used:** `Microsoft.OperationalInsights/workspaces/{name}/api/query` (read).

**Parameters:**

- `-SentinelWorkspaceId <ARM-resource-id>` (required): full ARM resource ID of the Log Analytics workspace linked to Sentinel.
- `-SentinelLookbackDays <int>` (default `30`): number of days to look back for active incidents (range 1-365).

**Sample command:**

```powershell
# Query active Sentinel incidents (last 30 days)
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "<sub-guid>" `
  -SentinelWorkspaceId "/subscriptions/<sub-guid>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<ws-name>"

# Custom lookback window (7 days)
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "<sub-guid>" `
  -SentinelWorkspaceId "/subscriptions/<sub-guid>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<ws-name>" `
  -SentinelLookbackDays 7

# Sentinel-only run
.\Invoke-AzureAnalyzer.ps1 -SentinelWorkspaceId "/subscriptions/<sub-guid>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<ws-name>" `
  -IncludeTools 'sentinel-incidents'
```

**What it scans:**

- Active (non-closed) SecurityIncident records within the lookback window.
- Per-incident metadata: title, severity, status, classification, owner, provider name, alert count, creation and last-modified timestamps.
- Incident URL for portal deep-link.

**What it does NOT do:**

- No incident closure, assignment, or status modification.
- No analytics rule creation or deployment.
- No alert suppression or dismissal.
- No custom table ingestion or DCR operations.
- Gracefully **skips** when the `SecurityIncident` table does not exist (Sentinel not enabled on the workspace).

---

### Microsoft Sentinel (Coverage / Posture)

The Sentinel coverage wrapper enumerates the same Log Analytics workspace's Sentinel posture surface via the `Microsoft.SecurityInsights` REST provider plus Log Analytics `savedSearches`. It surfaces detection-readiness gaps (missing or disabled analytic rules, undermonitored connector counts, empty / short-TTL watchlists, missing hunting queries) as findings keyed to the workspace ARM resource. Pairs with `sentinel-incidents` and uses the same RBAC.

| Token / scope | Why |
|---------------|-----|
| **Microsoft Sentinel Reader** on the workspace (or its resource group / subscription) | Required to list `Microsoft.SecurityInsights/alertRules`, `watchlists`, `watchlistItems`, and `dataConnectors` |
| **Log Analytics Reader** on the workspace | Required to list `Microsoft.OperationalInsights/workspaces/savedSearches` (hunting queries) |
| (Alternative) **Reader** on the workspace resource group | Sufficient when Reader permits the read endpoints above |

**API endpoints used (read-only):**

- `Microsoft.SecurityInsights/alertRules` (list) — analytic rule inventory and `enabled`/`lastModifiedUtc` state.
- `Microsoft.SecurityInsights/watchlists` (list) — watchlist metadata (`defaultDuration`, `watchlistAlias`).
- `Microsoft.SecurityInsights/watchlists/{alias}/watchlistItems` (list) — item count for empty-watchlist detection.
- `Microsoft.SecurityInsights/dataConnectors` (list) — connector inventory.
- `Microsoft.OperationalInsights/workspaces/savedSearches` (list) — saved searches filtered to category `Hunting Queries`.

**Parameters:**

- `-SentinelWorkspaceId <ARM-resource-id>` (required): full ARM resource ID of the Sentinel-linked Log Analytics workspace.
- `-SentinelLookbackDays <int>` (optional, default `30`): accepted for orchestrator-shape parity with `sentinel-incidents`; the wrapper currently uses a fixed 7-day staleness threshold for disabled analytic rules and a 30-day TTL threshold for watchlists.

**Sample command:**

```powershell
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "<sub-guid>" `
  -SentinelWorkspaceId "/subscriptions/<sub-guid>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<ws-name>" `
  -IncludeTools 'sentinel-coverage'
```

**What it scans:**

- Analytic-rule inventory (counts, enabled/disabled split, `lastModifiedUtc`).
- Data-connector inventory (count vs. minimum healthy threshold of 3).
- Watchlist inventory + per-watchlist `defaultDuration` (TTL parsing) + per-watchlist item count.
- Hunting-query inventory (saved searches whose `properties.category` matches `(?i)hunting`).

**What it does NOT do:**

- No analytic-rule create / update / delete / enable / disable.
- No watchlist mutation, item upload, or deletion.
- No data-connector connect / disconnect.
- No saved-search create / update / execute.
- Gracefully **skips** with `Status=Skipped` when `Microsoft.SecurityInsights` returns HTTP 404 / 409 (Sentinel not onboarded on the workspace).

**Categories deferred (require telemetry the read APIs do not expose):**

- *Enabled analytic rules with no incidents in 30 days* — needs a SecurityIncident KQL crossref per rule (`SecurityIncident | where AlertProductNames has 'Azure Sentinel' | summarize by AlertIds...`).
- *Hunting queries not run in 90 days* — `savedSearches` does not return a last-execution timestamp; would need workspace audit-log telemetry.

---

### Microsoft Graph (Maester -- identity security)

Maester requires delegated or application permissions to read Entra ID security configuration.

| Permission | Type | Why |
|------------|------|-----|
| **Directory.Read.All** | Application or Delegated | Read Entra ID users, groups, roles, and security configuration |
| **Policy.Read.All** | Application or Delegated | Read conditional access policies, sign-in risk policies, and other security policies |
| **Reports.Read.All** | Application or Delegated | Read sign-in reports and audit logs for security assessment |
| **DirectoryRecommendations.Read.All** | Application or Delegated | Read Entra ID recommendations (preview feature) |

**How to grant:**

For interactive use (delegated):
```powershell
# Connect to Graph with required scopes
$scopes = @(
  "Directory.Read.All",
  "Policy.Read.All",
  "Reports.Read.All",
  "DirectoryRecommendations.Read.All"
)
Connect-MgGraph -Scopes $scopes

# Run Maester
.\Invoke-AzureAnalyzer.ps1 -IncludeTools 'maester'
```

For service principals (application permissions):
1. Go to **Azure Portal** → **Entra ID** → **App registrations** → **Your app**
2. Select **API permissions**
3. Click **Add a permission** → **Microsoft Graph**
4. Choose **Application permissions**
5. Search for and select: `Directory.Read.All`, `Policy.Read.All`, `Reports.Read.All`, `DirectoryRecommendations.Read.All`
6. Click **Grant admin consent** (requires Entra ID admin)

**Important:** Maester does **NOT** modify your tenant. All permissions are read-only.

---

### GitHub (Scorecard -- repository security)

OpenSSF Scorecard evaluates repository security practices. Authentication is optional but **strongly recommended** to avoid rate limits.

| Token type | Scopes needed | Rate limit | Cost |
|------------|--------------|-----------|------|
| Unauthenticated | None (public repos) | 10 requests/minute | Free; very restrictive |
| Classic PAT | `repo` (or `public_repo` for public repos only) | 5,000 requests/hour | Free tier with GitHub account |
| Fine-grained PAT | Repository access: **Read** | 15,000 requests/hour | Free; more secure |

#### PR review gate workflow permissions

The PR review gate workflow (`.github/workflows/pr-review-gate.yml`) and the PR advisory gate workflow (`.github/workflows/pr-advisory-gate.yml`, #109) use least-privilege workflow permissions:

| Permission | Access | Why |
|---|---|---|
| `pull-requests` | `write` | Post consensus summary comments on PRs |
| `issues` | `write` | Future-proof for thread-linked issue comment sync and gate annotations |
| `contents` | `read` | Read repository scripts and workflow context during execution |

#### CI failure watchdog workflow permissions

The CI failure watchdog workflow (`.github/workflows/ci-failure-watchdog.yml`) uses `GITHUB_TOKEN` with least-privilege workflow permissions:

| Permission | Access | Why |
|---|---|---|
| `issues` | `write` | Create and update deduplicated `ci-failure` issues |
| `actions` | `read` | Read failed run metadata and failed-job logs |
| `contents` | `read` | Standard workflow repository read access |

#### GHEC-DR and GHES (enterprise instances)

For GitHub Enterprise Cloud with Data Residency (GHEC-DR) or GitHub Enterprise Server (GHES), the token must be created on the **enterprise instance** (not github.com). Use `-GitHubHost` to point Scorecard at the correct host (`github.com` remains the default).

| Requirement | Details |
|-------------|---------|
| **Token** | PAT created on the enterprise instance with `repo` scope (classic) or repository Read access (fine-grained) |
| **GH_HOST** | Set automatically via `-GitHubHost` parameter (e.g. `github.contoso.com`) |
| **Network** | The machine running azure-analyzer must be able to reach the enterprise host |

```powershell
# GHES example
$env:GITHUB_AUTH_TOKEN = "<enterprise-pat>"
.\Invoke-AzureAnalyzer.ps1 -Repository "github.contoso.com/org/repo" -GitHubHost "github.contoso.com"

# GHEC-DR example
$env:GITHUB_AUTH_TOKEN = "<ghec-dr-pat>"
.\Invoke-AzureAnalyzer.ps1 -Repository "github.eu.acme.com/org/repo" -GitHubHost "github.eu.acme.com"
```

**How to grant:**

**Option 1: Classic PAT (simplest)**
```powershell
# 1. Create token at https://github.com/settings/tokens/new
#    Scopes: repo (or public_repo for public repos only)
#    Name: azure-analyzer-scorecard
#    Expiration: 90 days

# 2. Set environment variable
$env:GITHUB_AUTH_TOKEN = "ghp_..."

# 3. Run Scorecard
.\Invoke-AzureAnalyzer.ps1 -IncludeTools 'scorecard' -Repository "github.com/org/repo"
```

**Option 2: Fine-grained PAT (recommended)**
```powershell
# 1. Create token at https://github.com/settings/personal-access-tokens/new
#    Permissions: Repository permissions → Contents: Read
#    Resource owner: Select your organization
#    Repositories: Select the repo(s) to scan

# 2. Set environment variable
$env:GITHUB_AUTH_TOKEN = (gh auth token)  # or manually paste the token

# 3. Run
.\Invoke-AzureAnalyzer.ps1 -IncludeTools 'scorecard' -Repository "github.com/org/repo"
```

**Option 3: GitHub CLI (automatic)**
```powershell
# If you already have GitHub CLI authenticated
$env:GITHUB_AUTH_TOKEN = (gh auth token)
.\Invoke-AzureAnalyzer.ps1 -IncludeTools 'scorecard' -Repository "github.com/org/repo"
```

---

### Local CLI tools (zizmor, gitleaks, Trivy)

These tools are **cloud-first**: when `-Repository` (GitHub) or `-AdoOrg`/`-AdoRepoUrl` (Azure DevOps) is provided, they scan a **remote** checkout via `modules/shared/RemoteClone.ps1` (HTTPS-only; host allow-list: `github.com`, `dev.azure.com`, `*.visualstudio.com`, `*.ghe.com`; tokens scrubbed from `.git/config` after clone). When neither is provided they fall back to scanning the local filesystem (`-RepoPath` / `-ScanPath`).

| Tool | What it scans | Remote auth (when targeting a remote repo) | Local fallback |
|------|--------------|-------------------------------------------|----------------|
| **zizmor** | GitHub Actions workflow YAML files for security anti-patterns | `GITHUB_AUTH_TOKEN` — fine-grained PAT with **Contents: Read** on the target repo, or classic PAT with `public_repo` / `repo` | Works on any local checkout; no token |
| **gitleaks** | Repository filesystem for hardcoded secrets. Invoked with `--redact` so the report file **never contains plaintext secrets** (Secret/Match fields are also stripped from parsed JSON as defense-in-depth). | `GITHUB_AUTH_TOKEN` (GitHub) or `AZURE_DEVOPS_EXT_PAT` with **Code: Read** (ADO) for private repos | Works on any local checkout; no token |
| **Trivy** | Dependency manifests (package-lock.json, requirements.txt, go.sum, etc.) for CVEs | `GITHUB_AUTH_TOKEN` / ADO PAT with **Code: Read** for private repos | Works on any local checkout; no token |

For public repos, no token is required. For private repos, use the **minimum-scope** token type listed above. All three tools operate read-only; no write permissions anywhere. If the CLI binary is missing the tool is skipped with an install instruction.

---

### Identity Correlator (cross-dimensional identity mapping)

The Identity Correlator runs in-process after all collectors complete. It seeds candidates from existing findings and cross-references them across dimensions — no additional permissions beyond whatever those collectors already had.
It also emits risk findings for privileged CI-linked identities, PAT-based ADO service connections, and identity reuse across multiple CI/CD bindings.

| Optional path | Requirement | Why |
|---|---|---|
| `-IncludeGraphLookup` | Microsoft Graph `Application.Read.All` (or Security Reader) | Look up federated identity credentials on candidate apps |

Without `-IncludeGraphLookup`, correlator runs with zero additional permissions.

---

### Identity Graph Expansion (cross-tenant B2B + SPN-to-resource edges)

The Identity Graph Expansion correlator builds a typed identity graph (entities **+ edges**) on top of the existing entity store. It emits five edge relations — `GuestOf`, `MemberOf`, `HasRoleOn`, `OwnsAppRegistration`, `ConsentedTo` — and risk findings for dormant guests, over-privileged SPN role assignments, and risky OAuth consents.

| Optional path | Requirement | Why |
|---|---|---|
| `-IncludeGraphLookup` (live mode) | Microsoft Graph `User.Read.All`, `Application.Read.All`, `Directory.Read.All` | Enumerate B2B guests, group memberships, SPN ownership, and admin consents (read-only) |
| Pre-fetched mode (`-PreFetchedData`) | None | Tests / replay scenarios consume a JSON fixture directly |
| ARM RBAC enrichment | `Microsoft.Authorization/roleAssignments/read` at the target scope (Reader inherits this) | Build `HasRoleOn` edges + over-privileged findings |

All Graph and ARM calls are read-only and wrapped in `Invoke-WithRetry`. Edges are persisted to `entities.json` under the v3.1 `Edges` array (back-compat readers fall back to v3.0 bare-array layout).

---

### Azure DevOps (ADO Service Connections -- service connection inventory)

The ADO service connection scanner requires a Personal Access Token (PAT) with read access to service endpoints.

| Token scope | Why |
|-------------|-----|
| **Service Connections (Read)** | Read service connection metadata (type, auth scheme, sharing status) across projects |
| **Project and Team (Read)** | List projects in the organization when `-AdoProject` is omitted |

**How to grant:**

1. Go to **Azure DevOps** → **User settings** → **Personal access tokens**
2. Click **New Token**
3. Set **Organization** to the target org (or "All accessible organizations")
4. Under **Scopes**, select:
   - **Service Connections**: Read
   - **Project and Team**: Read
5. Set expiration (recommended: 90 days)
6. Copy the token

**Usage:**

```powershell
# Option 1: Environment variable (recommended for CI)
$env:AZURE_DEVOPS_EXT_PAT = "<your-ado-pat>"
.\Invoke-AzureAnalyzer.ps1 -AdoOrg "contoso"
# Alternative env var:
$env:ADO_PAT_TOKEN = "<your-ado-pat>"
.\Invoke-AzureAnalyzer.ps1 -AdoOrganization "contoso"

# Option 2: Explicit parameter
.\Invoke-AzureAnalyzer.ps1 -AdoOrg "contoso" -AdoProject "my-project" -AdoPatToken "<your-ado-pat>"
# (PAT can also be resolved from ADO_PAT_TOKEN, AZURE_DEVOPS_EXT_PAT, or AZ_DEVOPS_PAT env vars)

# Option 3: Combine with Azure assessment
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -AdoOrg "contoso"
```

**Important:** The ADO scanner does **NOT** modify service connections or project settings. All API calls are read-only (`GET`).

This inventory surface pairs well with `ado-pipelines`, which answers where those identities are consumed.

---

### Azure DevOps (ADO Pipeline Security -- build/release definitions, variable groups, environments)

The ADO pipeline security collector inspects build definitions, classic release definitions, variable groups, and environments through the Azure DevOps REST API. It focuses on read-only posture signals: missing approvals on production-like environments, classic releases without approval coverage, plaintext secret-like library variables, and service-connection reuse across multiple pipeline assets.

| Token scope | Why |
|-------------|-----|
| **Build (Read)** | Read build definition metadata and trigger settings |
| **Release (Read)** | Read classic release definitions and stage approval metadata |
| **Library / Variable Groups (Read)** | Read variable-group metadata, secret flags, and Key Vault linkage state |
| **Environment (Read)** | Read environment definitions plus approval/check configuration |
| **Project and Team (Read)** | List projects when `-AdoProject` is omitted |

**How to grant:**

1. Go to **Azure DevOps** → **User settings** → **Personal access tokens**
2. Click **New Token**
3. Set **Organization** to the target org (or "All accessible organizations")
4. Under **Scopes**, select:
   - **Build**: Read
   - **Release**: Read
   - **Library / Variable Groups**: Read
   - **Environment**: Read
   - **Project and Team**: Read
5. Set expiration (recommended: 90 days)
6. Copy the token

**Usage:**

```powershell
# Recommended for CI or repeat runs
$env:AZURE_DEVOPS_EXT_PAT = "<your-ado-pat>"
.\Invoke-AzureAnalyzer.ps1 -AdoOrg "contoso" -IncludeTools 'ado-pipelines'

# Single project
.\Invoke-AzureAnalyzer.ps1 -AdoOrg "contoso" -AdoProject "payments" -IncludeTools 'ado-pipelines'

# Run both ADO collectors together
.\Invoke-AzureAnalyzer.ps1 -AdoOrg "contoso"
```

**What it scans:**

- Build definitions for broad CI trigger patterns and deployment identity references.
- Classic release definitions for production stages that lack approvals or gates.
- Variable groups for plaintext secret-like variables and missing Key Vault linkage.
- Environments for missing approval/check coverage on production-like targets.

**What it does NOT do:**

- No writes back to Azure DevOps.
- No log scraping or pipeline-run mutation.
- No emission of plaintext variable values; only metadata and variable names are surfaced.
- No task reputation scoring or YAML linting outside the scoped posture checks above.

---

### Azure DevOps (ADO Repo Secrets + Pipeline Correlator)

The ADO repo-secret scanner (`ado-repos-secrets`) and run correlator (`ado-pipeline-correlator`) are read-only and require only the minimum PAT scopes needed to enumerate repositories, inspect build runs, and correlate commit SHAs.

| Token scope | Why |
|-------------|-----|
| **Code (Read)** | Enumerate repositories and clone source for secret scanning |
| **Build (Read)** | Query build runs and run-log references (`builds` + `builds/{id}/logs`) |
| **Project and Team (Read)** | Enumerate projects when `-AdoProject` is omitted |

**Usage:**

```powershell
$env:AZURE_DEVOPS_EXT_PAT = "<your-ado-pat>"

# Repo secret scanning only
.\Invoke-AzureAnalyzer.ps1 -AdoOrg "contoso" -IncludeTools 'ado-repos-secrets'

# Correlation only (expects ado-repos-secrets output in the same run output folder)
.\Invoke-AzureAnalyzer.ps1 -AdoOrg "contoso" -IncludeTools 'ado-repos-secrets','ado-pipeline-correlator'
```

Both tools use HTTPS-only remote cloning via `modules/shared/RemoteClone.ps1`, enforce host allow-list checks, and never require write permissions.

---

### Optional: GitHub Copilot SDK (AI triage)

When running with `-EnableAiTriage`, non-compliant findings are sent to GitHub Copilot for AI analysis and remediation suggestions. **This is completely optional.**

| Requirement | Details |
|-------------|---------|
| **License** | GitHub Copilot Individual, Business, or Enterprise (if not licensed, AI triage is skipped) |
| **Token** | PAT with `copilot` scope, or existing `GITHUB_TOKEN` if already authenticated |
| **Environment variable** | `COPILOT_GITHUB_TOKEN` or `GITHUB_TOKEN` |
| **Privacy** | No data is sent to Copilot services unless `-EnableAiTriage` flag is used |

**How to grant:**

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

**Privacy note:** When Copilot SDK is enabled, only non-compliant finding details (title, severity, remediation) are sent for analysis. No credential or resource data is included.

---

## Permission matrix (quick reference)

| Tool | Azure Reader | Microsoft Graph | GitHub Token | ADO PAT | Local CLI | Copilot License |
|------|-------------|-----------------|-------------|---------|-----------|-----------------|
| **azqr** | ✅ Required | -- | -- | -- | -- | -- |
| **PSRule** | ✅ Required | -- | -- | -- | -- | -- |
| **AzGovViz** | ✅ Required | -- | -- | -- | -- | -- |
| **ALZ Queries** | ✅ Required | -- | -- | -- | -- | -- |
| **WARA** | ✅ Required | -- | -- | -- | -- | -- |
| **Azure Cost** | ✅ Required (Consumption API read) | -- | -- | -- | -- | -- |
| **Defender for Cloud** | ✅ Required (Microsoft.Security read) | -- | -- | -- | -- | -- |
| **Sentinel Incidents** | ✅ Required (Log Analytics Reader on workspace) | -- | -- | -- | -- | -- |
| **kubescape** | ✅ Reader (ARG AKS discovery) + AKS cluster-read RBAC (or kubeconfig) | -- | -- | -- | ✅ `kubescape`, `kubectl`, `az` | -- |
| **falco** | ✅ Reader (ARG + Microsoft.Security alert query); install mode also needs AKS cluster-read RBAC | -- | -- | -- | ⚡ Optional install mode: `helm`, `kubectl`, `az` | -- |
| **kube-bench** | ✅ Reader (ARG AKS discovery) + AKS RBAC Admin (create/delete Job in `kube-system`) | -- | -- | -- | ✅ `kubectl`, `az` | -- |
| **Maester** | -- | ✅ Required | -- | -- | -- | -- |
| **Scorecard** | -- | -- | ⚡ Recommended | -- | -- | -- |
| **ADO Connections** | -- | -- | -- | ✅ Required | -- | -- |
| **ADO Pipeline Security** | -- | -- | -- | ✅ Required | -- | -- |
| **ADO Repo Secrets** | -- | -- | -- | ✅ Required (Code:Read, Project:Read) | -- | -- |
| **ADO Pipeline Correlator** | -- | -- | -- | ✅ Required (Build:Read, Project:Read) | -- | -- |
| **zizmor** | -- | -- | ⚡ Remote | -- | ⚡ Local fallback | -- |
| **gitleaks** | -- | -- | ⚡ Remote | -- | ⚡ Local fallback | -- |
| **Trivy** | -- | -- | ⚡ Remote | -- | ⚡ Local fallback | -- |
| **bicep-iac** | -- | -- | ⚡ Remote (clone) | -- | ⚡ Local fallback (`bicep`) | -- |
| **terraform-iac** | -- | -- | ⚡ Remote (clone) | -- | ⚡ Local fallback (`terraform`/`trivy`) | -- |
| **Identity Correlator** | ✅ Inherited | ⚡ Optional (Graph lookup) | -- | -- | -- | -- |
| **Identity Graph Expansion** | ✅ Inherited | ⚡ Optional (`User.Read.All`, `Application.Read.All`, `Directory.Read.All` for live mode) | -- | -- | -- | -- |
| **Bicep IaC** | -- | -- | -- | -- | ⚡ `bicep` CLI | -- |
| **Terraform IaC** | -- | -- | -- | -- | ⚡ `terraform`, `trivy` CLIs | -- |
| **AI Triage** | -- | -- | ⚡ Recommended | -- | -- | ⚠️ Optional |

- ✅ = Required for tool to function
- ⚡ = Strongly recommended (improves rate limits, feature completeness)
- ⚠️ = Optional (license required only if you want AI analysis)
- -- = Not required for this tool

---

## Least-privilege principle

Azure-analyzer follows the principle of least privilege:

1. **Read-only everywhere** -- No write permissions on any scope (Azure, Graph, GitHub)
2. **Scoped to subscriptions/tenants** -- Not broader than necessary
3. **Graceful degradation** -- Missing permissions don't fail the run; the affected tool is skipped with a warning
4. **Tool-specific controls** -- Use `-IncludeTools` or `-ExcludeTools` to run only what you have access to

**Example: Run only tools you have permissions for**
```powershell
# If you don't have Microsoft Graph permissions, just run Azure tools
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -ExcludeTools 'maester'

# Or explicitly include only what you need
.\Invoke-AzureAnalyzer.ps1 -SubscriptionId "..." -IncludeTools 'azqr','psrule'
```

---

## What we do NOT need

- ❌ **Contributor** or **Owner** roles -- Reader is sufficient
- ❌ **Write permissions** to any Azure resource
- ❌ **Key Vault access** -- No secrets are read from or stored in Key Vault
- ❌ **Network permissions** -- No virtual network or firewall rules are modified
- ❌ **Azure DevOps write permissions** -- ADO service connection and pipeline scanners require only read access to metadata
- ❌ **Service Principal Password** -- Only object ID is needed for role assignment

### AI Triage (optional)

| Credential | Purpose |
|---|---|
| `COPILOT_GITHUB_TOKEN` / `GH_TOKEN` / `GITHUB_TOKEN` | Sends non-compliant finding data to GitHub Copilot API for AI-assisted triage. Only used when `-EnableAiTriage` is set. `ghs_` tokens NOT supported. See [docs/ai-triage.md](docs/ai-triage.md). |

---

## Troubleshooting

### Azure authentication
```powershell
# Check current Azure context
Get-AzContext

# Switch subscriptions if needed
Set-AzContext -SubscriptionId "<subscription-id>"

# Verify Reader permissions on your subscription
$role = Get-AzRoleAssignment -ObjectId (Get-AzContext).Account.ExtendedProperties.HomeAccountId -RoleDefinitionName Reader
if ($role) { Write-Host "✅ Reader role confirmed" } else { Write-Host "❌ Reader role not found" }
```

### Microsoft Graph authentication
```powershell
# Check Graph connection
Get-MgContext

# Re-authenticate with required scopes if needed
Disconnect-MgGraph
Connect-MgGraph -Scopes "Directory.Read.All", "Policy.Read.All", "Reports.Read.All"
```

### GitHub authentication
```powershell
# Verify token is set
if ($env:GITHUB_AUTH_TOKEN) { Write-Host "✅ Token is set" } else { Write-Host "❌ Token not found in env" }

# Test token rate limits
curl -H "Authorization: token $env:GITHUB_AUTH_TOKEN" https://api.github.com/rate_limit | jq '.rate_limit'
```

---

## See also

- [README.md](README.md) -- Quick start and tool overview
- [CONTRIBUTING.md](CONTRIBUTING.md) -- Development and PR process
- [SECURITY.md](SECURITY.md) -- Security practices and disclosure
