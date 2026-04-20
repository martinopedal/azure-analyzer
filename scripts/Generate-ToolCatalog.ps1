#requires -Version 7.0
<#
.SYNOPSIS
    Manifest-driven generator for the azure-analyzer tool catalogs.

.DESCRIPTION
    Reads tools/tool-manifest.json (single source of truth) and emits two
    Markdown catalog pages:

      docs/consumer/tool-catalog.md     consumer view (name, displayName,
                                        scope, provider, status, what-it-does,
                                        link to per-tool consumer doc when
                                        one exists)

      docs/contributor/tool-catalog.md  contributor view (full manifest fields:
                                        provider, scope, normalizer,
                                        invokeMethod, requiredPermissionTier,
                                        platforms, install kind / command,
                                        report color/phase, upstream pin)

    Both files include a clear GENERATED header that warns against hand-edits
    and points back to this script and the manifest.

    The generator is idempotent. Running it twice on a clean tree produces no
    diff. CI uses -CheckOnly mode to fail when the committed catalogs are
    stale relative to the manifest.

.PARAMETER ManifestPath
    Path to tools/tool-manifest.json. Defaults to the repo-relative location.

.PARAMETER ConsumerOutPath
    Path for the consumer-facing catalog. Defaults to docs/consumer/tool-catalog.md.

.PARAMETER ContributorOutPath
    Path for the contributor-facing catalog. Defaults to docs/contributor/tool-catalog.md.

.PARAMETER CheckOnly
    Do not write files. Compare the generated content with what is on disk.
    Exits 0 when in sync, exits 1 when stale (and prints the offending paths).

.EXAMPLE
    pwsh -File scripts/Generate-ToolCatalog.ps1
    Regenerate both catalog pages.

.EXAMPLE
    pwsh -File scripts/Generate-ToolCatalog.ps1 -CheckOnly
    Used by CI: fail if the committed catalog is stale.
#>
[CmdletBinding()]
param(
    [string]$ManifestPath,
    [string]$ConsumerOutPath,
    [string]$ContributorOutPath,
    [switch]$CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RepoRoot {
    $candidate = Split-Path -Parent $PSScriptRoot
    if (-not $candidate) { $candidate = (Get-Location).Path }
    return $candidate
}

$repoRoot = Get-RepoRoot
if (-not $ManifestPath)        { $ManifestPath        = Join-Path $repoRoot 'tools/tool-manifest.json' }
if (-not $ConsumerOutPath)     { $ConsumerOutPath     = Join-Path $repoRoot 'docs/consumer/tool-catalog.md' }
if (-not $ContributorOutPath)  { $ContributorOutPath  = Join-Path $repoRoot 'docs/contributor/tool-catalog.md' }

if (-not (Test-Path -LiteralPath $ManifestPath)) {
    throw "Manifest not found at: $ManifestPath"
}

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
if (-not $manifest.tools) {
    throw "Manifest at $ManifestPath has no 'tools' array."
}

$schemaVersion = if ($manifest.PSObject.Properties.Name -contains 'schemaVersion') { $manifest.schemaVersion } else { 'unknown' }

# Map of tool name -> consumer doc relative path (within docs/consumer). Add
# entries here as per-tool consumer pages are written. Missing entries fall
# back to the central scenarios/README index.
$consumerDocLinks = @{
    'maester'         = 'ai-triage.md'
    'gitleaks'        = 'gitleaks-pattern-tuning.md'
    'ado-repos-secrets' = 'gitleaks-pattern-tuning.md'
}

# Short, consumer-friendly description per tool. Falls back to displayName when
# absent so the catalog never ships an empty cell.
$consumerBlurb = @{
    'azqr'                     = 'Azure best-practice review across reliability, security, cost, performance and operational excellence.'
    'kubescape'                = 'Runtime posture for AKS clusters: misconfigurations, RBAC, network policies, vulnerabilities.'
    'kube-bench'               = 'CIS Kubernetes benchmark for AKS node hardening.'
    'defender-for-cloud'       = 'Pulls Microsoft Defender for Cloud Secure Score and active recommendations per subscription.'
    'falco'                    = 'AKS runtime anomaly detection (syscall-level threat detection).'
    'azure-cost'               = 'Per-subscription monthly Azure spend pulled from the Consumption API.'
    'finops'                   = 'FinOps signals: idle / orphaned resources that drive avoidable spend.'
    'loadtesting'              = 'Azure Load Testing reliability signals: failed runs, cancelled runs, and metric regressions.'
    'psrule'                   = 'Microsoft PSRule for Azure: Well-Architected and best-practice rule baseline.'
    'azgovviz'                 = 'Azure Governance Visualizer: management-group / subscription / RBAC / policy posture.'
    'alz-queries'              = 'ALZ Resource Graph queries: landing-zone compliance and drift detection.'
    'wara'                     = 'Well-Architected Reliability Assessment workflow for production workloads.'
    'maester'                  = 'Microsoft Entra (Identity) security baseline: conditional access, MFA, privileged roles.'
    'scorecard'                = 'OpenSSF Scorecard for repository supply-chain hygiene.'
    'ado-connections'          = 'Azure DevOps service-connection security: identity, scope, federation.'
    'ado-pipelines'            = 'Azure DevOps pipeline-security posture (variable groups, environments, approvals).'
    'ado-repos-secrets'        = 'Secret scanning across Azure DevOps repositories via gitleaks.'
    'ado-pipeline-correlator'  = 'Correlates ADO pipeline runs with downstream Azure resource changes.'
    'identity-correlator'      = 'Correlates Entra identities, role assignments, and resource ownership.'
    'identity-graph-expansion' = 'Expands the identity graph: cross-tenant B2B + service-principal-to-resource edges.'
    'zizmor'                   = 'Static analysis for GitHub Actions workflow security risks.'
    'gitleaks'                 = 'Secret scanning across local or remote git repositories.'
    'trivy'                    = 'Vulnerability and IaC misconfiguration scanner for repos and container images.'
    'bicep-iac'                = 'Bicep IaC validation: lint, build, and best-practice checks.'
    'terraform-iac'            = 'Terraform IaC validation: tflint / tfsec / checkov-style checks.'
    'infracost'                = 'Pre-deploy cost estimate for Terraform and Bicep resources.'
    'sentinel-incidents'       = 'Pulls active Microsoft Sentinel incidents from a Log Analytics workspace.'
    'sentinel-coverage'        = 'Sentinel detection posture: analytic rules, watchlists, data connectors, hunting queries.'
    'copilot-triage'           = 'Optional Copilot-powered AI triage for finding prioritization (disabled by default).'
}

function Format-Status {
    param($enabled)
    if ($enabled) { 'Enabled' } else { 'Disabled' }
}

function Format-InstallKind {
    param($tool)
    if ($tool.PSObject.Properties.Name -notcontains 'install' -or -not $tool.install) { return 'n/a' }
    $kind = $tool.install.kind
    $extra = ''
    switch ($kind) {
        'cli'       { if ($tool.install.PSObject.Properties.Name -contains 'command' -and $tool.install.command) { $extra = " (`"$($tool.install.command)`")" } }
        'psmodule'  { if ($tool.install.PSObject.Properties.Name -contains 'module'  -and $tool.install.module)  { $extra = " (`"$($tool.install.module)`")"  } }
        'gitclone'  { if ($tool.install.PSObject.Properties.Name -contains 'repo'    -and $tool.install.repo)    { $extra = " (`"$($tool.install.repo)`")"    } }
        default     { }
    }
    return "$kind$extra"
}

function Format-Upstream {
    param($tool)
    if ($tool.PSObject.Properties.Name -notcontains 'upstream' -or -not $tool.upstream) { return 'n/a' }
    $repo = if ($tool.upstream.PSObject.Properties.Name -contains 'repo') { $tool.upstream.repo } else { '' }
    $pin  = if ($tool.upstream.PSObject.Properties.Name -contains 'currentPin') { $tool.upstream.currentPin } else { '' }
    if ($repo -and $pin) { return "$repo @ $pin" }
    if ($repo) { return $repo }
    if ($pin)  { return $pin }
    return 'n/a'
}

function Format-Platforms {
    param($tool)
    if ($tool.PSObject.Properties.Name -notcontains 'platforms' -or -not $tool.platforms) { return 'n/a' }
    return ($tool.platforms -join ', ')
}

function Format-Color {
    param($tool)
    if ($tool.PSObject.Properties.Name -notcontains 'report' -or -not $tool.report) { return '' }
    if ($tool.report.PSObject.Properties.Name -contains 'color') { return $tool.report.color }
    return ''
}

function Format-Phase {
    param($tool)
    if ($tool.PSObject.Properties.Name -notcontains 'report' -or -not $tool.report) { return '' }
    if ($tool.report.PSObject.Properties.Name -contains 'phase') { return [string]$tool.report.phase }
    return ''
}

function Get-ConsumerDocLink {
    param([string]$name)
    if ($consumerDocLinks.ContainsKey($name)) {
        return "[docs](./$($consumerDocLinks[$name]))"
    }
    return '-'
}

function Get-ConsumerBlurb {
    param($tool)
    if ($consumerBlurb.ContainsKey($tool.name)) { return $consumerBlurb[$tool.name] }
    return $tool.displayName
}

function New-ConsumerCatalog {
    param($tools, [string]$schema)

    $enabledTools  = $tools | Where-Object { $_.enabled } | Sort-Object name
    $disabledTools = $tools | Where-Object { -not $_.enabled } | Sort-Object name

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('# Tool catalog (consumer view)')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('> GENERATED FROM tools/tool-manifest.json - do not edit by hand.')
    [void]$sb.AppendLine('> Regenerate with `pwsh -File scripts/Generate-ToolCatalog.ps1`.')
    [void]$sb.AppendLine('> Stale catalogs are blocked by the `tool-catalog-fresh` CI check.')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("Manifest schema version: ``$schema``")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("This page lists every analyzer tool azure-analyzer can run, what it covers, what scope it targets, and where to find consumer-focused setup notes when one exists. For the full manifest fields (normalizer, install kind, upstream pin, report color/phase) see [docs/contributor/tool-catalog.md](../contributor/tool-catalog.md).")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("**Total enabled:** $($enabledTools.Count). **Disabled / opt-in:** $($disabledTools.Count).")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('## Enabled by default')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('| Name | Display name | Scope | Provider | What it does | Docs |')
    [void]$sb.AppendLine('|---|---|---|---|---|---|')
    foreach ($t in $enabledTools) {
        $row = '| `{0}` | {1} | {2} | {3} | {4} | {5} |' -f `
            $t.name, $t.displayName, $t.scope, $t.provider, (Get-ConsumerBlurb $t), (Get-ConsumerDocLink $t.name)
        [void]$sb.AppendLine($row)
    }

    if ($disabledTools.Count -gt 0) {
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('## Disabled / opt-in')
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('These tools are wired but turned off in the manifest. Enable them by setting `enabled: true` in `tools/tool-manifest.json` or via `tools/install-config.json`.')
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('| Name | Display name | Scope | Provider | What it does |')
        [void]$sb.AppendLine('|---|---|---|---|---|')
        foreach ($t in $disabledTools) {
            $row = '| `{0}` | {1} | {2} | {3} | {4} |' -f `
                $t.name, $t.displayName, $t.scope, $t.provider, (Get-ConsumerBlurb $t)
            [void]$sb.AppendLine($row)
        }
    }

    [void]$sb.AppendLine()
    [void]$sb.AppendLine('## Scope reference')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('| Scope | Targets |')
    [void]$sb.AppendLine('|---|---|')
    [void]$sb.AppendLine('| `subscription` | Single Azure subscription (`-SubscriptionId`). |')
    [void]$sb.AppendLine('| `managementGroup` | Azure Management Group (`-ManagementGroupId`). |')
    [void]$sb.AppendLine('| `tenant` | Entra ID tenant (`-TenantId`, requires `Connect-MgGraph`). |')
    [void]$sb.AppendLine('| `repository` | GitHub or ADO repo (`-Repository` or `-RepoPath`). |')
    [void]$sb.AppendLine('| `ado` | Azure DevOps organization (`-AdoOrg`). |')
    [void]$sb.AppendLine('| `workspace` | Log Analytics / Sentinel workspace (`-SentinelWorkspaceId`). |')
    [void]$sb.AppendLine()
    return $sb.ToString()
}

function New-ContributorCatalog {
    param($tools, [string]$schema)

    $sortedTools = $tools | Sort-Object name

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('# Tool catalog (contributor view)')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('> GENERATED FROM tools/tool-manifest.json - do not edit by hand.')
    [void]$sb.AppendLine('> Regenerate with `pwsh -File scripts/Generate-ToolCatalog.ps1`.')
    [void]$sb.AppendLine('> Stale catalogs are blocked by the `tool-catalog-fresh` CI check.')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("Manifest schema version: ``$schema``")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('Full manifest projection: every wired tool with normalizer, invocation, install, report, and upstream metadata. For the consumer-friendly subset see [docs/consumer/tool-catalog.md](../consumer/tool-catalog.md). To onboard a new tool follow [adding-a-tool.md](./adding-a-tool.md).')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("**Total tools registered:** $($sortedTools.Count).")
    [void]$sb.AppendLine()

    [void]$sb.AppendLine('## Registration matrix')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('| Name | Display name | Type | Provider | Scope | Status | Tier | Platforms |')
    [void]$sb.AppendLine('|---|---|---|---|---|---|---|---|')
    foreach ($t in $sortedTools) {
        $type = if ($t.PSObject.Properties.Name -contains 'type') { $t.type } else { '' }
        $tier = if ($t.PSObject.Properties.Name -contains 'requiredPermissionTier') { [string]$t.requiredPermissionTier } else { '' }
        $row = '| `{0}` | {1} | {2} | {3} | {4} | {5} | {6} | {7} |' -f `
            $t.name, $t.displayName, $type, $t.provider, $t.scope, (Format-Status $t.enabled), $tier, (Format-Platforms $t)
        [void]$sb.AppendLine($row)
    }

    [void]$sb.AppendLine()
    [void]$sb.AppendLine('## Invocation')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('| Name | Normalizer | Invoke | Script / module | Required params |')
    [void]$sb.AppendLine('|---|---|---|---|---|')
    foreach ($t in $sortedTools) {
        $normalizer = if ($t.PSObject.Properties.Name -contains 'normalizer') { $t.normalizer } else { '' }
        $invoke     = if ($t.PSObject.Properties.Name -contains 'invokeMethod') { $t.invokeMethod } else { '' }
        $script     = if ($t.PSObject.Properties.Name -contains 'script') { $t.script } else { '' }
        $required   = if ($t.PSObject.Properties.Name -contains 'requiredParams' -and $t.requiredParams) { ($t.requiredParams -join ', ') } else { '-' }
        $row = '| `{0}` | `{1}` | {2} | `{3}` | {4} |' -f $t.name, $normalizer, $invoke, $script, $required
        [void]$sb.AppendLine($row)
    }

    [void]$sb.AppendLine()
    [void]$sb.AppendLine('## Install + upstream')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('| Name | Install kind | Upstream pin | Report color | Phase |')
    [void]$sb.AppendLine('|---|---|---|---|---|')
    foreach ($t in $sortedTools) {
        $row = '| `{0}` | {1} | {2} | `{3}` | {4} |' -f `
            $t.name, (Format-InstallKind $t), (Format-Upstream $t), (Format-Color $t), (Format-Phase $t)
        [void]$sb.AppendLine($row)
    }

    [void]$sb.AppendLine()
    [void]$sb.AppendLine('## Notes')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('- `tier` is `requiredPermissionTier` (0..6, see [docs/contributor/ARCHITECTURE.md](./ARCHITECTURE.md#permission-tiers-tier-06) for the tier breakdown).')
    [void]$sb.AppendLine('- `phase` is the report grouping hint used by `New-HtmlReport.ps1` and `New-MdReport.ps1`.')
    [void]$sb.AppendLine('- `report.color` is consumed by the per-source bar chart in the HTML report.')
    [void]$sb.AppendLine('- `install.kind` is one of `psmodule`, `cli`, `gitclone`, `none` and is enforced by `modules/shared/Installer.ps1`.')
    [void]$sb.AppendLine('- `upstream` drives the weekly auto-update loop; `pinType` and `currentPin` are managed by `tools/Update-ToolPins.ps1`.')
    [void]$sb.AppendLine()
    return $sb.ToString()
}

function Convert-ToLfText {
    param([string]$Text)
    return ($Text -replace "`r`n", "`n")
}

function Write-OrCheck {
    param(
        [string]$Path,
        [string]$Content,
        [switch]$CheckOnly
    )
    $normalized = Convert-ToLfText $Content
    if ($CheckOnly) {
        if (-not (Test-Path -LiteralPath $Path)) {
            Write-Host "[stale] missing: $Path"
            return $false
        }
        $current = Convert-ToLfText (Get-Content -LiteralPath $Path -Raw)
        if ($current -ne $normalized) {
            Write-Host "[stale] $Path differs from manifest projection"
            return $false
        }
        Write-Host "[ok] $Path"
        return $true
    }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    # Write LF-only, no BOM (consistent diff on Windows + Linux CI).
    [System.IO.File]::WriteAllText($Path, $normalized, [System.Text.UTF8Encoding]::new($false))
    Write-Host "[wrote] $Path"
    return $true
}

$consumerContent     = New-ConsumerCatalog $manifest.tools $schemaVersion
$contributorContent  = New-ContributorCatalog $manifest.tools $schemaVersion

$okConsumer    = Write-OrCheck -Path $ConsumerOutPath    -Content $consumerContent    -CheckOnly:$CheckOnly
$okContributor = Write-OrCheck -Path $ContributorOutPath -Content $contributorContent -CheckOnly:$CheckOnly

if ($CheckOnly -and (-not ($okConsumer -and $okContributor))) {
    Write-Host ''
    Write-Host 'Tool catalog is stale relative to tools/tool-manifest.json.'
    Write-Host 'Run: pwsh -File scripts/Generate-ToolCatalog.ps1'
    exit 1
}

exit 0
