# Helper for issue #432a — extract wrapper-emitted and normalizer-preserved
# fields per tool, dump JSON for downstream rendering. Audit-first, doc-only.
[CmdletBinding()]
param([string] $RepoRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
$manifest = Get-Content (Join-Path $RepoRoot 'tools\tool-manifest.json') -Raw | ConvertFrom-Json

$wrapperMap = @{
    'azqr'                     = 'Invoke-Azqr.ps1'
    'kubescape'                = 'Invoke-Kubescape.ps1'
    'kube-bench'               = 'Invoke-KubeBench.ps1'
    'defender-for-cloud'       = 'Invoke-DefenderForCloud.ps1'
    'prowler'                  = 'Invoke-Prowler.ps1'
    'falco'                    = 'Invoke-Falco.ps1'
    'azure-cost'               = 'Invoke-AzureCost.ps1'
    'azure-quota'              = 'Invoke-AzureQuotaReports.ps1'
    'finops'                   = 'Invoke-FinOpsSignals.ps1'
    'appinsights'              = 'Invoke-AppInsights.ps1'
    'loadtesting'              = 'Invoke-AzureLoadTesting.ps1'
    'aks-rightsizing'          = 'Invoke-AksRightsizing.ps1'
    'aks-karpenter-cost'       = 'Invoke-AksKarpenterCost.ps1'
    'psrule'                   = 'Invoke-PSRule.ps1'
    'powerpipe'                = 'Invoke-Powerpipe.ps1'
    'azgovviz'                 = 'Invoke-AzGovViz.ps1'
    'alz-queries'              = 'Invoke-AlzQueries.ps1'
    'wara'                     = 'Invoke-WARA.ps1'
    'maester'                  = 'Invoke-Maester.ps1'
    'scorecard'                = 'Invoke-Scorecard.ps1'
    'gh-actions-billing'       = 'Invoke-GhActionsBilling.ps1'
    'ado-connections'          = 'Invoke-ADOServiceConnections.ps1'
    'ado-pipelines'            = 'Invoke-ADOPipelineSecurity.ps1'
    'ado-consumption'          = 'Invoke-AdoConsumption.ps1'
    'ado-repos-secrets'        = 'Invoke-ADORepoSecrets.ps1'
    'ado-pipeline-correlator'  = 'Invoke-ADOPipelineCorrelator.ps1'
    'identity-correlator'      = 'shared\IdentityCorrelator.ps1'
    'identity-graph-expansion' = 'Invoke-IdentityGraphExpansion.ps1'
    'zizmor'                   = 'Invoke-Zizmor.ps1'
    'gitleaks'                 = 'Invoke-Gitleaks.ps1'
    'trivy'                    = 'Invoke-Trivy.ps1'
    'bicep-iac'                = 'Invoke-IaCBicep.ps1'
    'infracost'                = 'Invoke-Infracost.ps1'
    'terraform-iac'            = 'Invoke-IaCTerraform.ps1'
    'sentinel-incidents'       = 'Invoke-SentinelIncidents.ps1'
    'sentinel-coverage'        = 'Invoke-SentinelCoverage.ps1'
    'copilot-triage'           = 'Invoke-CopilotTriage.ps1'
}

$normalizerMap = @{
    'azqr' = 'Normalize-Azqr.ps1'; 'kubescape' = 'Normalize-Kubescape.ps1'
    'kube-bench' = 'Normalize-KubeBench.ps1'; 'defender-for-cloud' = 'Normalize-DefenderForCloud.ps1'
    'prowler' = 'Normalize-Prowler.ps1'; 'falco' = 'Normalize-Falco.ps1'
    'azure-cost' = 'Normalize-AzureCost.ps1'; 'azure-quota' = 'Normalize-AzureQuotaReports.ps1'
    'finops' = 'Normalize-FinOpsSignals.ps1'; 'appinsights' = 'Normalize-AppInsights.ps1'
    'loadtesting' = 'Normalize-AzureLoadTesting.ps1'; 'aks-rightsizing' = 'Normalize-AksRightsizing.ps1'
    'aks-karpenter-cost' = 'Normalize-AksKarpenterCost.ps1'; 'psrule' = 'Normalize-PSRule.ps1'
    'powerpipe' = 'Normalize-Powerpipe.ps1'; 'azgovviz' = 'Normalize-AzGovViz.ps1'
    'alz-queries' = 'Normalize-AlzQueries.ps1'; 'wara' = 'Normalize-WARA.ps1'
    'maester' = 'Normalize-Maester.ps1'; 'scorecard' = 'Normalize-Scorecard.ps1'
    'gh-actions-billing' = 'Normalize-GhActionsBilling.ps1'
    'ado-connections' = 'Normalize-ADOConnections.ps1'; 'ado-pipelines' = 'Normalize-ADOPipelineSecurity.ps1'
    'ado-consumption' = 'Normalize-AdoConsumption.ps1'; 'ado-repos-secrets' = 'Normalize-ADORepoSecrets.ps1'
    'ado-pipeline-correlator' = 'Normalize-ADOPipelineCorrelator.ps1'
    'identity-correlator' = 'Normalize-IdentityCorrelation.ps1'
    'identity-graph-expansion' = 'Normalize-IdentityGraphExpansion.ps1'
    'zizmor' = 'Normalize-Zizmor.ps1'; 'gitleaks' = 'Normalize-Gitleaks.ps1'
    'trivy' = 'Normalize-Trivy.ps1'; 'bicep-iac' = 'Normalize-IaCBicep.ps1'
    'infracost' = 'Normalize-Infracost.ps1'; 'terraform-iac' = 'Normalize-IaCTerraform.ps1'
    'sentinel-incidents' = 'Normalize-SentinelIncidents.ps1'
    'sentinel-coverage' = 'Normalize-SentinelCoverage.ps1'
    'copilot-triage' = $null
}

# FindingRow schema fields (modules/shared/Schema.ps1 — v2.2 additive set).
$schemaFields = @(
    'Id','Source','EntityId','EntityType','Title','RuleId','Compliant','ProvenanceRunId',
    'Category','Severity','Detail','Remediation','ResourceId','LearnMoreUrl','Platform',
    'SubscriptionId','SubscriptionName','ResourceGroup','ManagementGroupPath',
    'Frameworks','Controls','Confidence','EvidenceCount','MissingDimensions',
    'ProvenanceSource','ProvenanceRawRecordRef','ProvenanceTimestamp',
    'Pillar','Impact','Effort','DeepLinkUrl','RemediationSnippets','EvidenceUris',
    'BaselineTags','ScoreDelta','MitreTactics','MitreTechniques','EntityRefs','ToolVersion'
)

function Get-WrapperFields {
    param([string] $Path)
    if (-not $Path -or -not (Test-Path $Path)) { return @() }
    $text = Get-Content $Path -Raw
    $props = New-Object System.Collections.Generic.List[string]
    $rx = [regex]'(?ms)PSCustomObject\s*\]\s*@\{(.*?)\n\s*\}'
    foreach ($m in $rx.Matches($text)) {
        foreach ($line in $m.Groups[1].Value -split "`n") {
            if ($line -match '^\s*([A-Za-z][A-Za-z0-9_]*)\s*=') { $props.Add($matches[1]) }
        }
    }
    $rx2 = [regex]'(?ms)\$(?:row|finding|record|entry|item|out|result|envelope|signal)\w*\s*=\s*@\{(.*?)\n\s*\}'
    foreach ($m in $rx2.Matches($text)) {
        foreach ($line in $m.Groups[1].Value -split "`n") {
            if ($line -match '^\s*([A-Za-z][A-Za-z0-9_]*)\s*=') { $props.Add($matches[1]) }
        }
    }
    return ($props | Sort-Object -Unique)
}

function Get-NormalizerFields {
    param([string] $Path)
    if (-not $Path -or -not (Test-Path $Path)) { return @() }
    $text = Get-Content $Path -Raw
    $fields = New-Object System.Collections.Generic.List[string]
    $rx = [regex]'(?ms)New-FindingRow\b(.*?)(?:^\s*\}|\z)'
    foreach ($m in $rx.Matches($text)) {
        foreach ($p in [regex]::Matches($m.Groups[1].Value, '-([A-Z][A-Za-z0-9]+)\b')) {
            $fields.Add($p.Groups[1].Value)
        }
    }
    $rx2 = [regex]'(?ms)\$\w*[Pp]arams\s*=\s*@\{(.*?)\n\s*\}'
    foreach ($m in $rx2.Matches($text)) {
        foreach ($line in $m.Groups[1].Value -split "`n") {
            if ($line -match '^\s*([A-Z][A-Za-z0-9]+)\s*=') { $fields.Add($matches[1]) }
        }
    }
    return ($fields | Where-Object { $schemaFields -contains $_ } | Sort-Object -Unique)
}

$results = New-Object System.Collections.Generic.List[object]
foreach ($t in $manifest.tools) {
    $w = $wrapperMap[$t.name]
    $n = $normalizerMap[$t.name]
    $wPath = if ($w) { Join-Path $RepoRoot "modules\$w" } else { $null }
    $nPath = if ($n) { Join-Path $RepoRoot "modules\normalizers\$n" } else { $null }
    $wrapperExists = $wPath -and (Test-Path $wPath)
    $normExists = $nPath -and (Test-Path $nPath)
    $wrapperFields = if ($wrapperExists) { @(Get-WrapperFields -Path $wPath) } else { @() }
    $normFields = if ($normExists) { @(Get-NormalizerFields -Path $nPath) } else { @() }
    $missing = @($schemaFields | Where-Object { $_ -notin $normFields })
    $results.Add([pscustomobject]@{
        Tool                   = $t.name
        DisplayName            = $t.displayName
        Provider               = $t.provider
        Scope                  = $t.scope
        Enabled                = $t.enabled
        WrapperFile            = if ($wrapperExists) { (("modules/$w") -replace '\\','/') } else { $null }
        NormalizerFile         = if ($normExists) { "modules/normalizers/$n" } else { $null }
        WrapperFields          = $wrapperFields
        NormalizerSchemaFields = $normFields
        SchemaFieldsMissing    = $missing
    })
}

$out = Join-Path $RepoRoot 'audit-raw.json'
$results | ConvertTo-Json -Depth 6 | Set-Content -Path $out -Encoding UTF8
Write-Host "Wrote $out  ($($results.Count) tools)"
