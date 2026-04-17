# Permissions Reference -- azure-analyzer

## Core Principle

All tools operate **read-only** with no write permissions anywhere. Azure-analyzer uses only the minimum permissions required to assess your infrastructure.

Phase 0 v3 core modules (Schema, Canonicalize, EntityStore, tool manifest) introduce no new permissions or scopes.

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
| **kubescape** | Subscription | Reader + AKS cluster-read RBAC | Discovers AKS via ARG and runs in-cluster runtime posture scans through kubeconfig access |
| **falco** | Subscription | Reader (query mode) + optional AKS cluster-read RBAC for install mode | Reads Falco runtime alerts already present in Azure; optional install mode deploys Falco to AKS for short-lived runtime capture |
| **kube-bench** | Subscription | Reader + AKS RBAC Admin | Discovers AKS via ARG, applies a temporary kube-bench Job in `kube-system`, then collects node-level CIS results |

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
| **Repo-scoped** (Scorecard) | Independent of Azure hierarchy; runs for specified repo only |
| **CLI-scoped** (zizmor, gitleaks, Trivy) | Local filesystem tools; run automatically, no cloud scope needed |
| **ADO-scoped** (ADO Connections) | Independent of Azure hierarchy; runs when `-AdoOrg` is provided |

**Required permissions for recursion:**
- `Reader` on the management group (auto-inherited to all child subscriptions)
- **OR** `Reader` on each individual subscription (if you lack MG-level permissions)

**Discovery behavior:**
- **Tenant root group:** Include all subscriptions in the tenant
- **Specific MG:** Include only the MG and its direct children (recursive)
- **No recursion:** Use `-Recurse:$false` to scan only the specified MG, without discovering child subscriptions

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
| **kubescape** | ✅ Reader (ARG AKS discovery) + AKS cluster-read RBAC (or kubeconfig) | -- | -- | -- | ✅ `kubescape`, `kubectl`, `az` | -- |
| **falco** | ✅ Reader (ARG + Microsoft.Security alert query); install mode also needs AKS cluster-read RBAC | -- | -- | -- | ⚡ Optional install mode: `helm`, `kubectl`, `az` | -- |
| **kube-bench** | ✅ Reader (ARG AKS discovery) + AKS RBAC Admin (create/delete Job in `kube-system`) | -- | -- | -- | ✅ `kubectl`, `az` | -- |
| **Maester** | -- | ✅ Required | -- | -- | -- | -- |
| **Scorecard** | -- | -- | ⚡ Recommended | -- | -- | -- |
| **ADO Connections** | -- | -- | -- | ✅ Required | -- | -- |
| **zizmor** | -- | -- | ⚡ Remote | -- | ⚡ Local fallback | -- |
| **gitleaks** | -- | -- | ⚡ Remote | -- | ⚡ Local fallback | -- |
| **Trivy** | -- | -- | ⚡ Remote | -- | ⚡ Local fallback | -- |
| **Identity Correlator** | ✅ Inherited | ⚡ Optional (Graph lookup) | -- | -- | -- | -- |
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
- ❌ **Azure DevOps write permissions** -- ADO service connection scanner requires only read access to service endpoints
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
