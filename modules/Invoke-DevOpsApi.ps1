#Requires -Version 7.0
<#
.SYNOPSIS
    GitHub and Azure DevOps governance checks for DevOps maturity assessment.
.DESCRIPTION
    Checks branch protection rules, CODEOWNERS file, secret scanning, and Dependabot
    on GitHub repositories. ADO checks are parameterized and optional.
    Never throws — wraps all API calls, warns on failure, returns empty Findings on error.
.PARAMETER GitHubRepo
    GitHub repository in 'owner/repo' format. GitHub checks are skipped if not provided.
.PARAMETER GitHubToken
    GitHub personal access token. Falls back to $env:GITHUB_TOKEN if not provided.
.PARAMETER AdoOrg
    Azure DevOps organization name. ADO checks are skipped if not provided.
.PARAMETER AdoProject
    Azure DevOps project name.
.PARAMETER AdoToken
    Azure DevOps personal access token.
#>
[CmdletBinding()]
param (
    [string] $GitHubRepo,
    [string] $GitHubToken,
    [string] $AdoOrg,
    [string] $AdoProject,
    [string] $AdoToken
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$findings = [System.Collections.Generic.List[PSCustomObject]]::new()

# ---------------------------------------------------------------------------
# GitHub checks
# ---------------------------------------------------------------------------
if ([string]::IsNullOrEmpty($GitHubRepo)) {
    Write-Warning "DevOps API: No GitHubRepo provided — skipping GitHub checks."
} else {
    $parts = $GitHubRepo.Split('/')
    if ($parts.Count -ne 2 -or [string]::IsNullOrEmpty($parts[0]) -or [string]::IsNullOrEmpty($parts[1])) {
        Write-Warning "DevOps API: GitHubRepo '$GitHubRepo' must be in 'owner/repo' format — skipping GitHub checks."
    } else {
        $ghToken = if ($GitHubToken) { $GitHubToken } elseif ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { $null }
        $ghHeaders = if ($ghToken) {
            @{
                Authorization        = "Bearer $ghToken"
                Accept               = 'application/vnd.github+json'
                'X-GitHub-Api-Version' = '2022-11-28'
            }
        } else {
            @{}
        }

        $baseUri = "https://api.github.com/repos/$GitHubRepo"

        # ----------------------------------------------------------------
        # 1. Branch protection — main branch
        # ----------------------------------------------------------------
        try {
            $bp = Invoke-RestMethod -Uri "$baseUri/branches/main/protection" `
                -Headers $ghHeaders -ErrorAction SilentlyContinue

            if ($null -eq $bp) {
                $bpCompliant = $false
                $bpDetail    = 'Branch protection API returned no data for main branch.'
            } else {
                $prReviews   = $bp.PSObject.Properties['required_pull_request_reviews']?.Value
                $statusChecks = $bp.PSObject.Properties['required_status_checks']?.Value
                $reviewCount = if ($null -ne $prReviews) {
                    $prReviews.PSObject.Properties['required_approving_review_count']?.Value
                } else { 0 }
                $hasReviews  = ($null -ne $prReviews) -and ($reviewCount -ge 1)
                $hasChecks   = $null -ne $statusChecks
                $bpCompliant = $hasReviews -and $hasChecks
                $bpDetail    = if ($bpCompliant) {
                    "main branch protection: $reviewCount required reviewer(s), status checks enforced."
                } else {
                    $missing = @()
                    if (-not $hasReviews)  { $missing += 'required PR reviews (>=1)' }
                    if (-not $hasChecks)   { $missing += 'required status checks' }
                    "main branch protection missing: $($missing -join ', ')."
                }
            }
        } catch {
            $bpCompliant = $false
            $bpDetail    = "Branch protection not configured or inaccessible for main branch: $_"
        }

        $findings.Add([PSCustomObject]@{
            Id          = [guid]::NewGuid().ToString()
            Source      = 'devops-api'
            Category    = 'DevOps'
            Title       = 'Branch protection on main branch'
            Severity    = 'High'
            Compliant   = $bpCompliant
            Detail      = $bpDetail
            Remediation = "https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches"
        })

        # ----------------------------------------------------------------
        # 2. CODEOWNERS file
        # ----------------------------------------------------------------
        $codeownersCompliant = $false
        $codeownersDetail    = 'CODEOWNERS file not found.'
        $codeownersPaths     = @('.github/CODEOWNERS', 'CODEOWNERS', 'docs/CODEOWNERS')

        foreach ($coPath in $codeownersPaths) {
            try {
                $co = Invoke-RestMethod -Uri "$baseUri/contents/$coPath" `
                    -Headers $ghHeaders -ErrorAction SilentlyContinue
                if ($null -ne $co) {
                    $codeownersCompliant = $true
                    $codeownersDetail    = "CODEOWNERS file found at $coPath."
                    break
                }
            } catch {
                # 404 is expected for missing paths — continue to next
            }
        }

        $findings.Add([PSCustomObject]@{
            Id          = [guid]::NewGuid().ToString()
            Source      = 'devops-api'
            Category    = 'DevOps'
            Title       = 'CODEOWNERS file present'
            Severity    = 'Medium'
            Compliant   = $codeownersCompliant
            Detail      = $codeownersDetail
            Remediation = 'https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners'
        })

        # ----------------------------------------------------------------
        # 3 & 4. Secret scanning + Dependabot — fetch repo metadata once
        # ----------------------------------------------------------------
        $repoMeta = $null
        try {
            $repoMeta = Invoke-RestMethod -Uri $baseUri -Headers $ghHeaders -ErrorAction SilentlyContinue
        } catch {
            Write-Warning "DevOps API: Could not fetch repo metadata for $GitHubRepo : $_"
        }

        # 3. Secret scanning
        $secretCompliant = $false
        $secretDetail    = 'Secret scanning status unknown (could not retrieve repo metadata).'
        if ($null -ne $repoMeta) {
            $secAnalysis = $repoMeta.PSObject.Properties['security_and_analysis']?.Value
            if ($null -ne $secAnalysis) {
                $ss = $secAnalysis.PSObject.Properties['secret_scanning']?.Value
                $ssStatus = $ss?.PSObject.Properties['status']?.Value
                $secretCompliant = ($ssStatus -eq 'enabled')
                $secretDetail    = if ($secretCompliant) {
                    'Secret scanning is enabled on this repository.'
                } else {
                    "Secret scanning status: $($ssStatus ?? 'not configured'). Enable via Settings > Security > Code security."
                }
            } else {
                $secretDetail = 'security_and_analysis not returned — requires admin or organization repo scope.'
            }
        }

        $findings.Add([PSCustomObject]@{
            Id          = [guid]::NewGuid().ToString()
            Source      = 'devops-api'
            Category    = 'DevOps'
            Title       = 'Secret scanning enabled'
            Severity    = 'High'
            Compliant   = $secretCompliant
            Detail      = $secretDetail
            Remediation = 'https://docs.github.com/en/code-security/secret-scanning/enabling-secret-scanning-features/enabling-secret-scanning-for-your-repository'
        })

        # 4. Dependabot security updates
        $depCompliant = $false
        $depDetail    = 'Dependabot status unknown (could not retrieve repo metadata).'
        if ($null -ne $repoMeta) {
            $secAnalysis = $repoMeta.PSObject.Properties['security_and_analysis']?.Value
            if ($null -ne $secAnalysis) {
                $dsu = $secAnalysis.PSObject.Properties['dependabot_security_updates']?.Value
                $dsuStatus = $dsu?.PSObject.Properties['status']?.Value
                if ($dsuStatus -eq 'enabled') {
                    $depCompliant = $true
                    $depDetail    = 'Dependabot security updates are enabled.'
                } else {
                    # Fall back: check for dependabot.yml config file
                    try {
                        $depYml = Invoke-RestMethod -Uri "$baseUri/contents/.github/dependabot.yml" `
                            -Headers $ghHeaders -ErrorAction SilentlyContinue
                        if ($null -ne $depYml) {
                            $depCompliant = $true
                            $depDetail    = 'Dependabot configuration file (.github/dependabot.yml) found.'
                        } else {
                            $depDetail = "Dependabot status: $($dsuStatus ?? 'not configured'). No dependabot.yml found either."
                        }
                    } catch {
                        $depDetail = "Dependabot status: $($dsuStatus ?? 'not configured'). dependabot.yml not found."
                    }
                }
            } else {
                # Try dependabot.yml directly
                try {
                    $depYml = Invoke-RestMethod -Uri "$baseUri/contents/.github/dependabot.yml" `
                        -Headers $ghHeaders -ErrorAction SilentlyContinue
                    if ($null -ne $depYml) {
                        $depCompliant = $true
                        $depDetail    = 'Dependabot configuration file (.github/dependabot.yml) found.'
                    } else {
                        $depDetail = 'security_and_analysis not returned and no dependabot.yml found.'
                    }
                } catch {
                    $depDetail = 'security_and_analysis not returned and dependabot.yml not found.'
                }
            }
        }

        $findings.Add([PSCustomObject]@{
            Id          = [guid]::NewGuid().ToString()
            Source      = 'devops-api'
            Category    = 'DevOps'
            Title       = 'Dependabot security updates configured'
            Severity    = 'Medium'
            Compliant   = $depCompliant
            Detail      = $depDetail
            Remediation = 'https://docs.github.com/en/code-security/dependabot/dependabot-security-updates/configuring-dependabot-security-updates'
        })
    }
}

# ---------------------------------------------------------------------------
# ADO checks (optional — skipped if AdoOrg not provided)
# ---------------------------------------------------------------------------
if (-not [string]::IsNullOrEmpty($AdoOrg)) {
    if ([string]::IsNullOrEmpty($AdoProject)) {
        Write-Warning "DevOps API: AdoOrg provided but AdoProject is missing — skipping ADO checks."
    } else {
        $adoPat   = if ($AdoToken) { $AdoToken } elseif ($env:ADO_TOKEN) { $env:ADO_TOKEN } else { $null }
        $adoHeaders = if ($adoPat) {
            $encoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$adoPat"))
            @{ Authorization = "Basic $encoded" }
        } else {
            @{}
        }

        $adoBaseUri = "https://dev.azure.com/$AdoOrg/$AdoProject/_apis"

        # ADO: Branch policies on main
        try {
            $policies = Invoke-RestMethod -Uri "$adoBaseUri/policy/configurations?api-version=7.1" `
                -Headers $adoHeaders -ErrorAction SilentlyContinue
            $mainPolicies = if ($null -ne $policies -and $null -ne $policies.PSObject.Properties['value']?.Value) {
                @($policies.value | Where-Object {
                    $scope = $_.PSObject.Properties['settings']?.Value?.PSObject.Properties['scope']?.Value
                    $null -ne $scope -and ($scope | Where-Object { $_.PSObject.Properties['refName']?.Value -like '*main*' }).Count -gt 0
                })
            } else { @() }

            $adoBpCompliant = $mainPolicies.Count -gt 0
            $adoBpDetail    = if ($adoBpCompliant) {
                "$($mainPolicies.Count) branch policy/policies configured on main in $AdoOrg/$AdoProject."
            } else {
                "No branch policies found for main branch in $AdoOrg/$AdoProject."
            }
        } catch {
            $adoBpCompliant = $false
            $adoBpDetail    = "Could not retrieve ADO branch policies for $AdoOrg/$AdoProject: $_"
        }

        $findings.Add([PSCustomObject]@{
            Id          = [guid]::NewGuid().ToString()
            Source      = 'devops-api'
            Category    = 'DevOps'
            Title       = 'ADO branch policies on main'
            Severity    = 'High'
            Compliant   = $adoBpCompliant
            Detail      = $adoBpDetail
            Remediation = 'https://learn.microsoft.com/en-us/azure/devops/repos/git/branch-policies'
        })
    }
}

return [PSCustomObject]@{
    Source   = 'devops-api'
    Findings = $findings.ToArray()
}
