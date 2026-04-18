#Requires -Version 7.4
<#
.SYNOPSIS
    Azure DevOps pipeline security posture scanner.
.DESCRIPTION
    Queries Azure DevOps REST APIs to inspect build definitions, classic release
    definitions, variable groups, and environments. The first slice focuses on
    read-only posture signals such as missing approvals on production deploy
    surfaces, plaintext variable-group secrets, permissive CI triggers, and
    over-broad service-connection reuse. Variable values are never emitted.
.PARAMETER AdoOrg
    Azure DevOps organization name (required).
.PARAMETER AdoProject
    Project name. When omitted, all projects in the organization are scanned.
.PARAMETER AdoPat
    Personal access token. Falls back to ADO_PAT_TOKEN, AZURE_DEVOPS_EXT_PAT,
    or AZ_DEVOPS_PAT when not provided.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [Alias('AdoOrganization')]
    [ValidateNotNullOrEmpty()]
    [string] $AdoOrg,

    [string] $AdoProject,

    [Alias('AdoPatToken')]
    [string] $AdoPat
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sharedDir = Join-Path $PSScriptRoot 'shared'
. (Join-Path $sharedDir 'Retry.ps1')
. (Join-Path $sharedDir 'Sanitize.ps1')

$script:ServiceConnectionInputNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($inputName in @(
        'azureSubscription',
        'azureServiceConnection',
        'azureResourceManagerConnection',
        'connectedServiceName',
        'connectedServiceNameARM',
        'serviceConnection',
        'serviceEndpoint'
    )) {
    $null = $script:ServiceConnectionInputNames.Add($inputName)
}

function Resolve-AdoPat {
    param ([string] $Explicit)
    if ($Explicit) { return $Explicit }
    if ($env:ADO_PAT_TOKEN) { return $env:ADO_PAT_TOKEN }
    if ($env:AZURE_DEVOPS_EXT_PAT) { return $env:AZURE_DEVOPS_EXT_PAT }
    if ($env:AZ_DEVOPS_PAT) { return $env:AZ_DEVOPS_PAT }
    return $null
}

function Format-AdoSegment {
    param ([string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return 'unknown'
    }

    $normalized = $Value.Trim().ToLowerInvariant()
    $normalized = $normalized -replace '[\\/]+', '-'
    $normalized = $normalized -replace '\s+', '-'
    return $normalized
}

function Invoke-AdoApi {
    param (
        [Parameter(Mandatory)]
        [string] $Uri,

        [Parameter(Mandatory)]
        [hashtable] $Headers
    )

    Invoke-WithRetry -ScriptBlock {
        $webResponse = Invoke-WebRequest -Uri $Uri -Headers $Headers -Method Get -ContentType 'application/json'
        $bodyText = [string]$webResponse.Content
        $body = if ([string]::IsNullOrWhiteSpace($bodyText)) {
            [PSCustomObject]@{}
        } else {
            $bodyText | ConvertFrom-Json -Depth 100
        }

        $continuationToken = $null
        if ($webResponse.Headers -and $webResponse.Headers.ContainsKey('x-ms-continuationtoken')) {
            $tokenValue = $webResponse.Headers['x-ms-continuationtoken']
            if ($tokenValue -is [array]) {
                $continuationToken = $tokenValue[0]
            } else {
                $continuationToken = $tokenValue
            }
        }

        [PSCustomObject]@{
            Body              = $body
            ContinuationToken = $continuationToken
        }
    }
}

function Get-AdoPagedValues {
    param (
        [Parameter(Mandatory)]
        [string] $Uri,

        [Parameter(Mandatory)]
        [hashtable] $Headers
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $continuationToken = $null

    do {
        $pagedUri = $Uri
        if ($continuationToken) {
            $separator = if ($pagedUri -like '*?*') { '&' } else { '?' }
            $pagedUri += "$separator" + 'continuationToken=' + [uri]::EscapeDataString([string]$continuationToken)
        }

        $response = Invoke-AdoApi -Uri $pagedUri -Headers $Headers
        $body = if ($response) { $response.Body } else { $null }

        if ($body -and $body.PSObject.Properties['value']) {
            foreach ($item in @($body.value)) {
                $items.Add($item)
            }
        } elseif ($body) {
            $items.Add($body)
        }

        $continuationToken = if ($response) { $response.ContinuationToken } else { $null }
    } while ($continuationToken)

    return @($items)
}

function Get-AdoProjects {
    param (
        [string] $Org,
        [hashtable] $Headers
    )

    $orgEnc = [uri]::EscapeDataString($Org)
    $uri = "https://dev.azure.com/$orgEnc/_apis/projects?api-version=7.1&`$top=100"
    $projects = Get-AdoPagedValues -Uri $uri -Headers $Headers
    return @($projects | Where-Object { $_.name } | ForEach-Object { $_.name })
}

function Get-BuildDefinitions {
    param (
        [string] $Org,
        [string] $Project,
        [hashtable] $Headers
    )

    $orgEnc = [uri]::EscapeDataString($Org)
    $projectEnc = [uri]::EscapeDataString($Project)
    $uri = "https://dev.azure.com/$orgEnc/$projectEnc/_apis/build/definitions?api-version=7.1&includeAllProperties=true&`$top=100"
    return @(Get-AdoPagedValues -Uri $uri -Headers $Headers)
}

function Get-ReleaseDefinitions {
    param (
        [string] $Org,
        [string] $Project,
        [hashtable] $Headers
    )

    $orgEnc = [uri]::EscapeDataString($Org)
    $projectEnc = [uri]::EscapeDataString($Project)
    $uri = "https://vsrm.dev.azure.com/$orgEnc/$projectEnc/_apis/release/definitions?api-version=7.1&`$top=100"
    return @(Get-AdoPagedValues -Uri $uri -Headers $Headers)
}

function Get-VariableGroups {
    param (
        [string] $Org,
        [string] $Project,
        [hashtable] $Headers
    )

    $orgEnc = [uri]::EscapeDataString($Org)
    $projectEnc = [uri]::EscapeDataString($Project)
    $uri = "https://dev.azure.com/$orgEnc/$projectEnc/_apis/distributedtask/variablegroups?api-version=7.1-preview.2&`$top=100"
    return @(Get-AdoPagedValues -Uri $uri -Headers $Headers)
}

function Get-Environments {
    param (
        [string] $Org,
        [string] $Project,
        [hashtable] $Headers
    )

    $orgEnc = [uri]::EscapeDataString($Org)
    $projectEnc = [uri]::EscapeDataString($Project)
    $uri = "https://dev.azure.com/$orgEnc/$projectEnc/_apis/distributedtask/environments?api-version=7.1-preview.1&`$top=100"
    return @(Get-AdoPagedValues -Uri $uri -Headers $Headers)
}

function Get-EnvironmentChecks {
    param (
        [string] $Org,
        [string] $Project,
        [int] $EnvironmentId,
        [hashtable] $Headers
    )

    if ($EnvironmentId -le 0) {
        return [PSCustomObject]@{
            Success = $true
            Checks  = @()
            Error   = ''
        }
    }

    $orgEnc = [uri]::EscapeDataString($Org)
    $projectEnc = [uri]::EscapeDataString($Project)
    $uri = "https://dev.azure.com/$orgEnc/$projectEnc/_apis/pipelines/checks/configurations?resourceType=environment&resourceId=$EnvironmentId&api-version=7.1-preview.1"

    try {
        return [PSCustomObject]@{
            Success = $true
            Checks  = @(Get-AdoPagedValues -Uri $uri -Headers $Headers)
            Error   = ''
        }
    } catch {
        $sanitized = Remove-Credentials "Could not read environment checks for '$Project/$EnvironmentId': $($_.Exception.Message)"
        Write-Verbose $sanitized
        return [PSCustomObject]@{
            Success = $false
            Checks  = @()
            Error   = $sanitized
        }
    }
}

function Get-CollectionCount {
    param ([object] $Value)

    if ($null -eq $Value) { return 0 }
    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) { return 0 }
        return 1
    }
    if ($Value -is [System.Collections.IDictionary]) { return $Value.Count }
    if ($Value -is [System.Collections.IEnumerable]) {
        $count = 0
        foreach ($item in $Value) {
            $count++
        }
        return $count
    }
    return 1
}

function Test-IsProductionName {
    param ([string] $Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    return $Name -match '(?i)(^|[-_\s])(prod|production|live|prd)($|[-_\s])'
}

function Test-IsSensitiveVariableName {
    param ([string] $Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    return $Name -match '(?i)(secret|password|token|key|credential|connectionstring|clientsecret|apikey|pat)'
}

function Test-IsGuidLike {
    param ([AllowNull()] [object] $Value)

    if ($null -eq $Value) { return $false }

    $candidate = if ($Value -is [string]) {
        $Value.Trim()
    } else {
        [string]$Value
    }

    if ([string]::IsNullOrWhiteSpace($candidate)) { return $false }

    $guidValue = [guid]::Empty
    return [guid]::TryParse($candidate, [ref]$guidValue)
}

function Test-IsServiceConnectionProperty {
    param (
        [string] $Name,
        [AllowNull()] [object] $Value
    )

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($script:ServiceConnectionInputNames.Contains($Name)) { return $true }

    if ($Name -notmatch '(?i)(connectedservice(name(arm)?)?|serviceconnection(id)?|serviceendpoint(id)?|endpointid)$') {
        return $false
    }

    if (Test-IsGuidLike -Value $Value) {
        return $true
    }

    if ($null -ne $Value -and $Value.PSObject.Properties['id'] -and (Test-IsGuidLike -Value $Value.id)) {
        return $true
    }

    return $false
}

function Add-ServiceConnectionRefs {
    param (
        [object] $Node,
        [System.Collections.Generic.HashSet[string]] $Results
    )

    if ($null -eq $Node) { return }
    if ($Node -is [string]) { return }

    $properties = @()
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($key in $Node.Keys) {
            $properties += [PSCustomObject]@{ Name = [string]$key; Value = $Node[$key] }
        }
    } else {
        $properties = @($Node.PSObject.Properties)
    }

    foreach ($property in $properties) {
        $propName = [string]$property.Name
        $propValue = $property.Value

        if (Test-IsServiceConnectionProperty -Name $propName -Value $propValue) {
            if ($propValue -is [string]) {
                $candidate = $propValue.Trim()
                if ($candidate -and $candidate.Length -le 200) {
                    $null = $Results.Add($candidate)
                }
            } elseif ($null -ne $propValue) {
                if ($propValue.PSObject.Properties['name'] -and $propValue.name) {
                    $null = $Results.Add([string]$propValue.name)
                } elseif ($propValue.PSObject.Properties['id'] -and $propValue.id) {
                    $null = $Results.Add([string]$propValue.id)
                }
            }
        }

        if ($null -eq $propValue -or $propValue -is [string]) { continue }
        if ($propValue -is [System.Collections.IEnumerable] -and -not ($propValue -is [string])) {
            foreach ($item in $propValue) {
                Add-ServiceConnectionRefs -Node $item -Results $Results
            }
            continue
        }

        if ($propValue -is [System.Collections.IDictionary] -or @($propValue.PSObject.Properties).Count -gt 0) {
            Add-ServiceConnectionRefs -Node $propValue -Results $Results
        }
    }
}

function Get-ServiceConnectionReferences {
    param ([object] $Node)

    $results = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    Add-ServiceConnectionRefs -Node $Node -Results $results
    return @($results | Sort-Object)
}

function Get-VariableGroupReferences {
    param ([object] $Node)

    $results = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($null -eq $Node) { return @() }

    $variableGroups = @()
    if ($Node.PSObject.Properties['variableGroups']) {
        $variableGroups = @($Node.variableGroups)
    }

    foreach ($group in $variableGroups) {
        if ($group -is [string] -or $group -is [int]) {
            $null = $results.Add([string]$group)
            continue
        }
        if ($group.PSObject.Properties['name'] -and $group.name) {
            $null = $results.Add([string]$group.name)
        } elseif ($group.PSObject.Properties['id'] -and $group.id) {
            $null = $results.Add([string]$group.id)
        }
    }

    return @($results | Sort-Object)
}

function Test-AnyBranchTrigger {
    param ([object] $Definition)

    if (-not $Definition.PSObject.Properties['triggers']) { return $false }

    foreach ($trigger in @($Definition.triggers)) {
        $triggerType = if ($trigger.PSObject.Properties['triggerType']) { [string]$trigger.triggerType } else { '' }
        if ([string]::IsNullOrWhiteSpace($triggerType)) {
            continue
        }

        if ($triggerType -notmatch '(?i)^(continuousintegration|batchedcontinuousintegration|gatedcheckin|pullrequest)$') {
            continue
        }

        $branchFilters = @()
        if ($trigger.PSObject.Properties['branchFilters']) {
            $branchFilters = @($trigger.branchFilters | Where-Object { $_ })
        }

        if ($branchFilters.Count -eq 0) {
            return $true
        }
    }

    return $false
}

function Get-StageApprovalCount {
    param ([object] $Stage)

    $count = 0

    foreach ($propName in @('approvals', 'checks')) {
        if ($Stage.PSObject.Properties[$propName]) {
            $count += Get-CollectionCount -Value $Stage.$propName
        }
    }

    foreach ($propName in @('preDeployApprovals', 'postDeployApprovals')) {
        if (-not $Stage.PSObject.Properties[$propName]) { continue }
        $approvalNode = $Stage.$propName
        if ($approvalNode -and $approvalNode.PSObject.Properties['approvals']) {
            $count += Get-CollectionCount -Value $approvalNode.approvals
        } else {
            $count += Get-CollectionCount -Value $approvalNode
        }
    }

    foreach ($propName in @('preDeploymentGates', 'postDeploymentGates')) {
        if ($Stage.PSObject.Properties[$propName]) {
            $count += Get-CollectionCount -Value $Stage.$propName
        }
    }

    return $count
}

function New-PipelineFinding {
    param (
        [string] $Org,
        [string] $Project,
        [string] $AssetType,
        [string] $AssetId,
        [string] $AssetName,
        [string] $Category,
        [string] $Title,
        [bool] $Compliant,
        [string] $Severity,
        [string] $Detail,
        [string] $Remediation,
        [string] $LearnMoreUrl,
        [string] $ResourceId
    )

    [PSCustomObject]@{
        Source        = 'ado-pipelines'
        ResourceId    = $ResourceId
        Category      = $Category
        Title         = (Remove-Credentials $Title)
        Compliant     = [bool]$Compliant
        Severity      = $Severity
        Detail        = (Remove-Credentials $Detail)
        Remediation   = (Remove-Credentials $Remediation)
        LearnMoreUrl  = $LearnMoreUrl
        SchemaVersion = '1.0'
        AdoOrg        = $Org
        AdoProject    = $Project
        AssetType     = $AssetType
        AssetId       = $AssetId
        AssetName     = $AssetName
    }
}

$pat = Resolve-AdoPat -Explicit $AdoPat
if (-not $pat) {
    return [PSCustomObject]@{
        Source   = 'ado-pipelines'
        Status   = 'Skipped'
        Message  = 'No ADO PAT provided. Set -AdoPat/-AdoPatToken, ADO_PAT_TOKEN, AZURE_DEVOPS_EXT_PAT, or AZ_DEVOPS_PAT.'
        Findings = @()
    }
}

$pair = ":$pat"
$bytes = [System.Text.Encoding]::UTF8.GetBytes($pair)
$base64 = [System.Convert]::ToBase64String($bytes)
$headers = @{ Authorization = "Basic $base64" }

try {
    [string[]]$projects = @()
    if ($AdoProject) {
        $projects = @([string]$AdoProject)
    } else {
        $projects = @(Get-AdoProjects -Org $AdoOrg -Headers $headers)
    }

    if ($projects.Count -eq 0) {
        return [PSCustomObject]@{
            Source   = 'ado-pipelines'
            Status   = 'Success'
            Message  = "No projects found in organization '$AdoOrg'."
            Findings = @()
        }
    }

    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()
    $failedProjects = [System.Collections.Generic.List[string]]::new()
    $partialProjects = [System.Collections.Generic.List[string]]::new()
    $serviceConnectionUsage = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($project in $projects) {
        try {
            $buildDefinitions = @(Get-BuildDefinitions -Org $AdoOrg -Project $project -Headers $headers)
            $releaseDefinitions = @(Get-ReleaseDefinitions -Org $AdoOrg -Project $project -Headers $headers)
            $variableGroups = @(Get-VariableGroups -Org $AdoOrg -Project $project -Headers $headers)
            $environments = @(Get-Environments -Org $AdoOrg -Project $project -Headers $headers)

            foreach ($definition in $buildDefinitions) {
                $definitionId = if ($definition.PSObject.Properties['id'] -and $definition.id) { [string]$definition.id } else { '' }
                $definitionName = if ($definition.PSObject.Properties['name'] -and $definition.name) { [string]$definition.name } else { "build-$definitionId" }
                $serviceRefs = @(Get-ServiceConnectionReferences -Node $definition)
                $variableGroupRefs = @(Get-VariableGroupReferences -Node $definition)

                foreach ($ref in $serviceRefs) {
                    if (-not $serviceConnectionUsage.ContainsKey($ref)) {
                        $serviceConnectionUsage[$ref] = [System.Collections.Generic.List[string]]::new()
                    }
                    $serviceConnectionUsage[$ref].Add("$project|pipeline|$definitionName")
                }

                $assetKey = if ($definitionId) { $definitionId } else { $definitionName }
                $resourceId = "ado://$(Format-AdoSegment $AdoOrg)/$(Format-AdoSegment $project)/pipeline/$(Format-AdoSegment $assetKey)"
                $defaultBranch = if ($definition.PSObject.Properties['repository'] -and $definition.repository -and $definition.repository.PSObject.Properties['defaultBranch']) {
                    [string]$definition.repository.defaultBranch
                } else {
                    ''
                }

                $inventoryTitle = "Pipeline definition: $definitionName"
                $inventoryDetail = "ServiceConnections=$($serviceRefs.Count); VariableGroups=$($variableGroupRefs.Count); DefaultBranch=$defaultBranch"
                $findings.Add((New-PipelineFinding -Org $AdoOrg -Project $project -AssetType 'Pipeline' -AssetId $definitionId -AssetName $definitionName -Category 'Pipeline Definition' -Title $inventoryTitle -Compliant $true -Severity 'Info' -Detail $inventoryDetail -Remediation '' -LearnMoreUrl 'https://learn.microsoft.com/en-us/azure/devops/pipelines/process/pipeline-triggers' -ResourceId $resourceId))

                if ((Test-IsProductionName -Name $definitionName) -and (Test-AnyBranchTrigger -Definition $definition)) {
                    $findings.Add((New-PipelineFinding -Org $AdoOrg -Project $project -AssetType 'Pipeline' -AssetId $definitionId -AssetName $definitionName -Category 'Pipeline Definition' -Title "Pipeline '$definitionName' allows broad branch triggers" -Compliant $false -Severity 'Low' -Detail 'The definition appears to be production-facing but its CI trigger has no explicit branch filters.' -Remediation 'Restrict CI triggers to protected branches only (for example main/release/*) and require PR validation before deployment.' -LearnMoreUrl 'https://learn.microsoft.com/en-us/azure/devops/pipelines/repos/azure-repos-git?view=azure-devops&tabs=yaml#ci-triggers' -ResourceId $resourceId))
                }
            }

            foreach ($releaseDefinition in $releaseDefinitions) {
                $releaseId = if ($releaseDefinition.PSObject.Properties['id'] -and $releaseDefinition.id) { [string]$releaseDefinition.id } else { '' }
                $releaseName = if ($releaseDefinition.PSObject.Properties['name'] -and $releaseDefinition.name) { [string]$releaseDefinition.name } else { "release-$releaseId" }
                $releaseKey = if ($releaseId) { $releaseId } else { $releaseName }
                $resourceId = "ado://$(Format-AdoSegment $AdoOrg)/$(Format-AdoSegment $project)/pipeline/release-$(Format-AdoSegment $releaseKey)"

                $missingStages = [System.Collections.Generic.List[string]]::new()
                $stages = if ($releaseDefinition.PSObject.Properties['environments']) { @($releaseDefinition.environments) } else { @() }
                foreach ($stage in $stages) {
                    if ($null -eq $stage) { continue }

                    $stageName = if ($stage.PSObject.Properties['name'] -and $stage.name) { [string]$stage.name } else { 'unnamed-stage' }
                    if (-not (Test-IsProductionName -Name $stageName)) { continue }

                    $approvalCount = Get-StageApprovalCount -Stage $stage
                    if ($approvalCount -eq 0) {
                        $missingStages.Add($stageName)
                    }

                    foreach ($ref in @(Get-ServiceConnectionReferences -Node $stage)) {
                        if (-not $serviceConnectionUsage.ContainsKey($ref)) {
                            $serviceConnectionUsage[$ref] = [System.Collections.Generic.List[string]]::new()
                        }
                        $serviceConnectionUsage[$ref].Add("$project|release|$releaseName/$stageName")
                    }
                }

                if ($missingStages.Count -gt 0) {
                    $stageList = ($missingStages | Select-Object -Unique) -join ', '
                    $findings.Add((New-PipelineFinding -Org $AdoOrg -Project $project -AssetType 'Pipeline' -AssetId $releaseId -AssetName $releaseName -Category 'Release Definition' -Title "Release definition '$releaseName' has production stages without approvals" -Compliant $false -Severity 'High' -Detail "Production stages without approval evidence: $stageList." -Remediation 'Add pre-deployment approvals or equivalent environment checks before production release stages.' -LearnMoreUrl 'https://learn.microsoft.com/en-us/azure/devops/pipelines/release/approvals/' -ResourceId $resourceId))
                } else {
                    $findings.Add((New-PipelineFinding -Org $AdoOrg -Project $project -AssetType 'Pipeline' -AssetId $releaseId -AssetName $releaseName -Category 'Release Definition' -Title "Release definition '$releaseName' has deployment approval coverage" -Compliant $true -Severity 'Info' -Detail 'No production stages were found without approval or gate metadata.' -Remediation '' -LearnMoreUrl 'https://learn.microsoft.com/en-us/azure/devops/pipelines/release/approvals/' -ResourceId $resourceId))
                }
            }

            foreach ($group in $variableGroups) {
                $groupId = if ($group.PSObject.Properties['id'] -and $group.id) { [string]$group.id } else { '' }
                $groupName = if ($group.PSObject.Properties['name'] -and $group.name) { [string]$group.name } else { "group-$groupId" }
                $groupKey = if ($groupName) { $groupName } else { $groupId }
                $resourceId = "ado://$(Format-AdoSegment $AdoOrg)/$(Format-AdoSegment $project)/variablegroup/$(Format-AdoSegment $groupKey)"
                $isKeyVaultLinked = $false
                if ($group.PSObject.Properties['type'] -and [string]$group.type -eq 'AzureKeyVault') {
                    $isKeyVaultLinked = $true
                } elseif ($group.PSObject.Properties['providerData'] -and $group.providerData) {
                    $isKeyVaultLinked = $true
                }

                $plaintextSensitiveNames = [System.Collections.Generic.List[string]]::new()
                $plaintextCount = 0

                if ($group.PSObject.Properties['variables'] -and $group.variables) {
                    foreach ($property in @($group.variables.PSObject.Properties)) {
                        $variableName = [string]$property.Name
                        $variableMeta = $property.Value
                        $isSecret = $false
                        if ($null -ne $variableMeta -and $variableMeta.PSObject.Properties['isSecret']) {
                            $isSecret = [bool]$variableMeta.isSecret
                        }

                        if (-not $isSecret) {
                            $plaintextCount++
                            if (Test-IsSensitiveVariableName -Name $variableName) {
                                $plaintextSensitiveNames.Add($variableName)
                            }
                        }
                    }
                }

                if ($plaintextSensitiveNames.Count -gt 0) {
                    $namePreview = ($plaintextSensitiveNames | Select-Object -First 5) -join ', '
                    $findings.Add((New-PipelineFinding -Org $AdoOrg -Project $project -AssetType 'VariableGroup' -AssetId $groupId -AssetName $groupName -Category 'Variable Group' -Title "Variable group '$groupName' contains plaintext sensitive variables" -Compliant $false -Severity 'High' -Detail "Variable names marked as non-secret: $namePreview. Values were intentionally omitted." -Remediation 'Convert these variables to secret variables or link the group to Azure Key Vault.' -LearnMoreUrl 'https://learn.microsoft.com/en-us/azure/devops/pipelines/library/variable-groups' -ResourceId $resourceId))
                } elseif ((-not $isKeyVaultLinked) -and $plaintextCount -gt 0 -and (Test-IsProductionName -Name $groupName)) {
                    $findings.Add((New-PipelineFinding -Org $AdoOrg -Project $project -AssetType 'VariableGroup' -AssetId $groupId -AssetName $groupName -Category 'Variable Group' -Title "Production variable group '$groupName' is not linked to Key Vault" -Compliant $false -Severity 'Medium' -Detail "The group contains $plaintextCount non-secret variable(s) and is stored as a standard library group." -Remediation 'Prefer Azure Key Vault-linked variable groups for production deployments and keep only non-sensitive metadata inline.' -LearnMoreUrl 'https://learn.microsoft.com/en-us/azure/devops/pipelines/library/link-variable-groups-to-key-vaults' -ResourceId $resourceId))
                } else {
                    $detail = if ($isKeyVaultLinked) {
                        'Key Vault linkage detected.'
                    } else {
                        "No plaintext sensitive variable names detected. Non-secret variable count=$plaintextCount."
                    }
                    $findings.Add((New-PipelineFinding -Org $AdoOrg -Project $project -AssetType 'VariableGroup' -AssetId $groupId -AssetName $groupName -Category 'Variable Group' -Title "Variable group '$groupName' passed the initial posture sweep" -Compliant $true -Severity 'Info' -Detail $detail -Remediation '' -LearnMoreUrl 'https://learn.microsoft.com/en-us/azure/devops/pipelines/library/variable-groups' -ResourceId $resourceId))
                }
            }

            foreach ($environment in $environments) {
                $environmentId = if ($environment.PSObject.Properties['id'] -and $environment.id) { [int]$environment.id } else { 0 }
                $environmentName = if ($environment.PSObject.Properties['name'] -and $environment.name) { [string]$environment.name } else { "environment-$environmentId" }
                $environmentKey = if ($environmentName) { $environmentName } else { $environmentId }
                $resourceId = "ado://$(Format-AdoSegment $AdoOrg)/$(Format-AdoSegment $project)/environment/$(Format-AdoSegment $environmentKey)"

                $checkResult = Get-EnvironmentChecks -Org $AdoOrg -Project $project -EnvironmentId $environmentId -Headers $headers
                $checks = @($checkResult.Checks)
                $checkCount = Get-CollectionCount -Value $checks

                if (-not $checkResult.Success) {
                    $partialProjects.Add($project)
                    $findings.Add((New-PipelineFinding -Org $AdoOrg -Project $project -AssetType 'Environment' -AssetId ([string]$environmentId) -AssetName $environmentName -Category 'Environment' -Title "Environment '$environmentName' check coverage could not be verified" -Compliant $false -Severity 'Info' -Detail 'Environment checks could not be retrieved for this scan, so the result is partial and should be re-run once the Azure DevOps checks API is reachable.' -Remediation 'Verify that the token can read environment checks, then re-run the scan to confirm approvals are configured.' -LearnMoreUrl 'https://learn.microsoft.com/en-us/azure/devops/pipelines/process/approvals?view=azure-devops' -ResourceId $resourceId))
                } elseif ((Test-IsProductionName -Name $environmentName) -and $checkCount -eq 0) {
                    $findings.Add((New-PipelineFinding -Org $AdoOrg -Project $project -AssetType 'Environment' -AssetId ([string]$environmentId) -AssetName $environmentName -Category 'Environment' -Title "Environment '$environmentName' has no approval checks" -Compliant $false -Severity 'High' -Detail 'No approval, branch control, or other environment checks were returned for this production-like environment.' -Remediation 'Configure environment approvals or checks before allowing production deployments.' -LearnMoreUrl 'https://learn.microsoft.com/en-us/azure/devops/pipelines/process/approvals?view=azure-devops' -ResourceId $resourceId))
                } else {
                    $findings.Add((New-PipelineFinding -Org $AdoOrg -Project $project -AssetType 'Environment' -AssetId ([string]$environmentId) -AssetName $environmentName -Category 'Environment' -Title "Environment '$environmentName' has check coverage" -Compliant $true -Severity 'Info' -Detail "Environment checks detected: $checkCount." -Remediation '' -LearnMoreUrl 'https://learn.microsoft.com/en-us/azure/devops/pipelines/process/approvals?view=azure-devops' -ResourceId $resourceId))
                }
            }
        } catch {
            Write-Warning (Remove-Credentials "Failed to scan project '$project': $_")
            $failedProjects.Add($project)
        }
    }

    foreach ($usageEntry in $serviceConnectionUsage.GetEnumerator()) {
        $uniqueConsumers = @($usageEntry.Value | Select-Object -Unique)
        if ($uniqueConsumers.Count -lt 3) { continue }

        $consumerPreview = ($uniqueConsumers | Select-Object -First 5) -join '; '
        $connectionName = [string]$usageEntry.Key
        $findings.Add((New-PipelineFinding -Org $AdoOrg -Project 'shared' -AssetType 'ServiceConnection' -AssetId $connectionName -AssetName $connectionName -Category 'Service Connection Usage' -Title "Service connection '$connectionName' is reused across multiple pipeline assets" -Compliant $false -Severity 'Medium' -Detail "Referenced by $($uniqueConsumers.Count) assets: $consumerPreview" -Remediation 'Review whether this identity is over-scoped or should be split by environment or application boundary.' -LearnMoreUrl 'https://learn.microsoft.com/en-us/azure/devops/pipelines/library/service-endpoints' -ResourceId "ado://$(Format-AdoSegment $AdoOrg)/shared/serviceconnection/$(Format-AdoSegment $connectionName)"))
    }

    $status = if ($failedProjects.Count -gt 0 -and $failedProjects.Count -lt $projects.Count) {
        'PartialSuccess'
    } elseif ($failedProjects.Count -ge $projects.Count -and $projects.Count -gt 0) {
        'Failed'
    } elseif ($partialProjects.Count -gt 0) {
        'PartialSuccess'
    } else {
        'Success'
    }

    $message = "Scanned $($projects.Count) project(s), produced $($findings.Count) pipeline security finding(s)."
    if ($failedProjects.Count -gt 0) {
        $message += " Failed projects: $($failedProjects -join ', ')."
    }
    if ($partialProjects.Count -gt 0) {
        $message += " Partial environment-check coverage in: $((@($partialProjects | Select-Object -Unique)) -join ', ')."
    }

    return [PSCustomObject]@{
        Source   = 'ado-pipelines'
        Status   = $status
        Message  = (Remove-Credentials $message)
        Findings = @($findings)
    }
} catch {
    $msg = Remove-Credentials $_.Exception.Message
    Write-Warning "ADO pipeline security scan failed: $msg"
    return [PSCustomObject]@{
        Source   = 'ado-pipelines'
        Status   = 'Failed'
        Message  = $msg
        Findings = @()
    }
}
