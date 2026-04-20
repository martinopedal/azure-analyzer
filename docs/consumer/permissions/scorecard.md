# OpenSSF Scorecard - Required Permissions

**Display name:** OpenSSF Scorecard

**Scope:** repository | **Provider:** github

OpenSSF Scorecard evaluates repository security practices. Authentication is optional but **strongly recommended** to avoid rate limits.

## Required tokens

| Token type | Scopes needed | Rate limit | Cost |
|------------|--------------|-----------|------|
| Unauthenticated | None (public repos) | 10 requests / minute | Free; very restrictive |
| Classic PAT | `repo` (or `public_repo` for public repos only) | 5,000 requests / hour | Free tier with GitHub account |
| Fine-grained PAT | Repository access: **Read** | 15,000 requests / hour | Free; more secure |

## Workflow permissions (when run from CI)

### PR review gate workflow

The PR review gate workflow (`.github/workflows/pr-review-gate.yml`) and the PR advisory gate workflow (`.github/workflows/pr-advisory-gate.yml`, #109) use least-privilege workflow permissions:

| Permission | Access | Why |
|---|---|---|
| `pull-requests` | `write` | Post consensus summary comments on PRs |
| `issues` | `write` | Future-proof for thread-linked issue comment sync and gate annotations |
| `contents` | `read` | Read repository scripts and workflow context during execution |

### CI failure watchdog workflow

The CI failure watchdog workflow (`.github/workflows/ci-failure-watchdog.yml`) uses `GITHUB_TOKEN` with least-privilege workflow permissions:

| Permission | Access | Why |
|---|---|---|
| `issues` | `write` | Create and update deduplicated `ci-failure` issues |
| `actions` | `read` | Read failed run metadata and failed-job logs |
| `contents` | `read` | Standard workflow repository read access |

## GHEC-DR and GHES (enterprise instances)

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

## How to grant

### Option 1: Classic PAT (simplest)

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

### Option 2: Fine-grained PAT (recommended)

```powershell
# 1. Create token at https://github.com/settings/personal-access-tokens/new
#    Permissions: Repository permissions -> Contents: Read
#    Resource owner: Select your organization
#    Repositories: Select the repo(s) to scan

# 2. Set environment variable
$env:GITHUB_AUTH_TOKEN = (gh auth token)  # or manually paste the token

# 3. Run
.\Invoke-AzureAnalyzer.ps1 -IncludeTools 'scorecard' -Repository "github.com/org/repo"
```

### Option 3: GitHub CLI (automatic)

```powershell
# If you already have GitHub CLI authenticated
$env:GITHUB_AUTH_TOKEN = (gh auth token)
.\Invoke-AzureAnalyzer.ps1 -IncludeTools 'scorecard' -Repository "github.com/org/repo"
```
