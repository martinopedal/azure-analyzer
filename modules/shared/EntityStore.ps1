#Requires -Version 7.4
<#
.SYNOPSIS
    In-memory entity and finding store with spill-to-disk support.
.DESCRIPTION
    Maintains deduplicated entities and findings, merging duplicates per the
    schema v2 dedup contract. Supports disk spill when memory limits are hit.
#>
[CmdletBinding()]
param ()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SeverityRank = @{
    Critical = 5
    High     = 4
    Medium   = 3
    Low      = 2
    Info     = 1
}

function Get-SeverityRank {
    param ([string] $Severity)
    if (-not $Severity) { return 0 }
    return $script:SeverityRank[$Severity] ?? 0
}

function Get-NonEmptyValue {
    param ([object] $Current, [object] $Incoming)

    if ($null -ne $Current) {
        if ($Current -is [string]) {
            if (-not [string]::IsNullOrWhiteSpace($Current)) { return $Current }
        } elseif ($Current -is [System.Collections.IEnumerable]) {
            if (@($Current).Count -gt 0) { return $Current }
        } else {
            return $Current
        }
    }

    return $Incoming
}

function Merge-UniqueByKey {
    param (
        [object[]] $Existing,
        [object[]] $Incoming,
        [scriptblock] $KeySelector
    )

    $result = [System.Collections.Generic.List[object]]::new()
    $lookup = @{}

    foreach ($item in @($Existing)) {
        if (-not $item) { continue }
        $key = & $KeySelector $item
        if (-not $key) { continue }
        if (-not $lookup.ContainsKey($key)) {
            $lookup[$key] = $item
            $result.Add($item)
        }
    }

    foreach ($item in @($Incoming)) {
        if (-not $item) { continue }
        $key = & $KeySelector $item
        if (-not $key) { continue }
        if (-not $lookup.ContainsKey($key)) {
            $lookup[$key] = $item
            $result.Add($item)
        }
    }

    return $result.ToArray()
}

function Merge-MissingDimensions {
    param (
        [string[]] $Existing,
        [string[]] $Incoming
    )

    if ($Existing -and $Incoming) {
        return @($Existing | Where-Object { $Incoming -contains $_ })
    }

    if (-not $Existing -and $Incoming) {
        return @($Incoming)
    }

    return $Existing
}

function Get-ObjectPropertyValue {
    param (
        [object] $Object,
        [string] $PropertyName,
        [object] $Default = $null
    )

    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$PropertyName]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function New-StoreEntity {
    param (
        [pscustomobject] $EntityStub,
        [string] $EntityId,
        [string] $EntityType,
        [string] $Platform
    )

    $observations = [System.Collections.Generic.List[pscustomobject]]::new()
    if ($EntityStub -and $EntityStub.Observations) {
        foreach ($obs in @($EntityStub.Observations)) {
            if ($obs) { $observations.Add($obs) }
        }
    }

    $displayName = $null
    $subscriptionId = $null
    $subscriptionName = $null
    $resourceGroup = $null
    $managementGroupPath = $null
    $externalIds = $null
    $worstSeverity = $null
    $compliantCount = 0
    $nonCompliantCount = 0
    $sources = @()
    $monthlyCost = $null
    $currency = $null
    $costTrend = $null
    $frameworks = $null
    $controls = $null
    $policies = $null
    $correlations = $null
    $confidence = $null
    $missingDimensions = $null

    if ($null -ne $EntityStub) {
        $displayName = Get-ObjectPropertyValue -Object $EntityStub -PropertyName 'DisplayName'
        $subscriptionId = Get-ObjectPropertyValue -Object $EntityStub -PropertyName 'SubscriptionId'
        $subscriptionName = Get-ObjectPropertyValue -Object $EntityStub -PropertyName 'SubscriptionName'
        $resourceGroup = Get-ObjectPropertyValue -Object $EntityStub -PropertyName 'ResourceGroup'
        $managementGroupPath = Get-ObjectPropertyValue -Object $EntityStub -PropertyName 'ManagementGroupPath'
        $externalIds = Get-ObjectPropertyValue -Object $EntityStub -PropertyName 'ExternalIds'
        $worstSeverity = Get-ObjectPropertyValue -Object $EntityStub -PropertyName 'WorstSeverity'
        $entityCompliantCount = Get-ObjectPropertyValue -Object $EntityStub -PropertyName 'CompliantCount'
        if ($null -ne $entityCompliantCount) { $compliantCount = $entityCompliantCount }
        $entityNonCompliantCount = Get-ObjectPropertyValue -Object $EntityStub -PropertyName 'NonCompliantCount'
        if ($null -ne $entityNonCompliantCount) { $nonCompliantCount = $entityNonCompliantCount }
        $entitySources = Get-ObjectPropertyValue -Object $EntityStub -PropertyName 'Sources'
        if ($null -ne $entitySources) { $sources = $entitySources }
        $monthlyCost = Get-ObjectPropertyValue -Object $EntityStub -PropertyName 'MonthlyCost'
        $currency = Get-ObjectPropertyValue -Object $EntityStub -PropertyName 'Currency'
        $costTrend = Get-ObjectPropertyValue -Object $EntityStub -PropertyName 'CostTrend'
        $frameworks = Get-ObjectPropertyValue -Object $EntityStub -PropertyName 'Frameworks'
        $controls = Get-ObjectPropertyValue -Object $EntityStub -PropertyName 'Controls'
        $policies = Get-ObjectPropertyValue -Object $EntityStub -PropertyName 'Policies'
        $correlations = Get-ObjectPropertyValue -Object $EntityStub -PropertyName 'Correlations'
        $confidence = Get-ObjectPropertyValue -Object $EntityStub -PropertyName 'Confidence'
        $missingDimensions = Get-ObjectPropertyValue -Object $EntityStub -PropertyName 'MissingDimensions'
    }

    [PSCustomObject]@{
        EntityId         = $EntityId
        EntityType       = $EntityType
        Platform         = $Platform
        DisplayName      = $displayName
        SubscriptionId   = $subscriptionId
        SubscriptionName = $subscriptionName
        ResourceGroup    = $resourceGroup
        ManagementGroupPath = $managementGroupPath
        ExternalIds      = $externalIds
        Observations     = $observations
        WorstSeverity    = $worstSeverity
        CompliantCount   = $compliantCount
        NonCompliantCount = $nonCompliantCount
        Sources          = $sources
        MonthlyCost      = $monthlyCost
        Currency         = $currency
        CostTrend        = $costTrend
        Frameworks       = $frameworks
        Controls         = $controls
        Policies         = $policies
        Correlations     = $correlations
        Confidence       = $confidence
        MissingDimensions = $missingDimensions
    }
}

class EntityStore {
    [hashtable] $Entities
    [System.Collections.Generic.List[pscustomobject]] $Findings
    [hashtable] $FindingIndex
    [int] $MaxEntitiesInMemory = 50000
    [int] $SpillFileCount = 0
    [string] $OutputPath

    EntityStore([int] $MaxEntitiesInMemory = 50000, [string] $OutputPath = $(Join-Path (Get-Location) 'output')) {
        $this.Entities = @{}
        $this.Findings = [System.Collections.Generic.List[pscustomobject]]::new()
        $this.FindingIndex = @{}

        if ($env:AZURE_ANALYZER_MAX_ENTITIES) {
            $parsed = 0
            if ([int]::TryParse($env:AZURE_ANALYZER_MAX_ENTITIES, [ref]$parsed) -and $parsed -gt 0) {
                $this.MaxEntitiesInMemory = $parsed
            } else {
                $this.MaxEntitiesInMemory = $MaxEntitiesInMemory
            }
        } else {
            $this.MaxEntitiesInMemory = $MaxEntitiesInMemory
        }

        $this.OutputPath = $OutputPath
        if (-not (Test-Path $this.OutputPath)) {
            $null = New-Item -ItemType Directory -Path $this.OutputPath -Force
        }
    }

    [string] GetEntityKey([string] $Platform, [string] $EntityType, [string] $EntityId) {
        return "$Platform|$EntityType|$EntityId"
    }

    [string] GetFindingKey([pscustomobject] $Finding) {
        if (-not $Finding -or [string]::IsNullOrWhiteSpace([string]$Finding.EntityId)) {
            return $null
        }
        return "$($Finding.Source)|$($Finding.EntityId)|$($Finding.Title)|$($Finding.Compliant)"
    }

    [void] MergeFinding([pscustomobject] $Target, [pscustomobject] $Incoming) {
        if (-not $Target -or -not $Incoming) { return }

        if ((Get-SeverityRank $Incoming.Severity) -gt (Get-SeverityRank $Target.Severity)) {
            $Target.Severity = $Incoming.Severity
        }

        $targetDetailLength = 0
        if (($null -ne $Target) -and ($null -ne $Target.Detail)) { $targetDetailLength = $Target.Detail.Length }
        if ($Incoming.Detail -and ($Incoming.Detail.Length -gt $targetDetailLength)) {
            $Target.Detail = $Incoming.Detail
        }

        $targetRemediationLength = 0
        if (($null -ne $Target) -and ($null -ne $Target.Remediation)) { $targetRemediationLength = $Target.Remediation.Length }
        if ($Incoming.Remediation -and ($Incoming.Remediation.Length -gt $targetRemediationLength)) {
            $Target.Remediation = $Incoming.Remediation
        }

        if (-not $Target.LearnMoreUrl -and $Incoming.LearnMoreUrl) {
            $Target.LearnMoreUrl = $Incoming.LearnMoreUrl
        }

        if ($Incoming.Provenance) {
            if (-not $Target.Provenance) {
                $Target.Provenance = $Incoming.Provenance
            } else {
                $existingStamp = $null
                $incomingStamp = $null
                if ($Target.Provenance.Timestamp) {
                    $existingStamp = Get-Date $Target.Provenance.Timestamp -ErrorAction SilentlyContinue
                }
                if ($Incoming.Provenance.Timestamp) {
                    $incomingStamp = Get-Date $Incoming.Provenance.Timestamp -ErrorAction SilentlyContinue
                }
                if (-not $existingStamp -or ($incomingStamp -and $incomingStamp -lt $existingStamp)) {
                    $Target.Provenance = $Incoming.Provenance
                }
            }
        }
    }

    [void] UpdateEntityAggregates([pscustomobject] $Entity, [pscustomobject] $Finding) {
        if (-not $Entity -or -not $Finding) { return }

        if (-not $Entity.Sources) { $Entity.Sources = @() }
        if ($Finding.Source -and -not ($Entity.Sources -contains $Finding.Source)) {
            $Entity.Sources += $Finding.Source
        }

        if ($Finding.Severity -and ((Get-SeverityRank $Finding.Severity) -gt (Get-SeverityRank $Entity.WorstSeverity))) {
            $Entity.WorstSeverity = $Finding.Severity
        }

        if ($Finding.Compliant -is [bool]) {
            if ($Finding.Compliant) { $Entity.CompliantCount++ } else { $Entity.NonCompliantCount++ }
        }
    }

    [void] AddFinding([pscustomobject] $Finding) {
        if (-not $Finding) {
            throw "Finding cannot be null."
        }

        $findingKey = $this.GetFindingKey($Finding)
        $targetFinding = $Finding

        if ($findingKey -and $this.FindingIndex.ContainsKey($findingKey)) {
            $existing = $this.FindingIndex[$findingKey]
            $this.MergeFinding($existing, $Finding)
            $targetFinding = $existing
        } else {
            $this.Findings.Add($Finding)
            if ($findingKey) {
                $this.FindingIndex[$findingKey] = $Finding
            }
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$Finding.EntityId)) {
            $entityKey = $this.GetEntityKey($Finding.Platform, $Finding.EntityType, $Finding.EntityId)
            $entity = $this.Entities[$entityKey]
            if (-not $entity) {
                $entity = New-StoreEntity -EntityStub $null -EntityId $Finding.EntityId -EntityType $Finding.EntityType -Platform $Finding.Platform
                $this.Entities[$entityKey] = $entity
            }

            try {
                $this.MergeEntityMetadata([pscustomobject]@{
                    EntityId            = $Finding.EntityId
                    EntityType          = $Finding.EntityType
                    Platform            = $Finding.Platform
                    DisplayName         = $(if ($Finding.PSObject.Properties['DisplayName']) { $Finding.DisplayName } else { $null })
                    SubscriptionId      = $(if ($Finding.PSObject.Properties['SubscriptionId']) { $Finding.SubscriptionId } else { $null })
                    SubscriptionName    = $(if ($Finding.PSObject.Properties['SubscriptionName']) { $Finding.SubscriptionName } else { $null })
                    ResourceGroup       = $(if ($Finding.PSObject.Properties['ResourceGroup']) { $Finding.ResourceGroup } else { $null })
                    ManagementGroupPath = $(if ($Finding.PSObject.Properties['ManagementGroupPath']) { $Finding.ManagementGroupPath } else { $null })
                    Frameworks          = $(if ($Finding.PSObject.Properties['Frameworks']) { $Finding.Frameworks } else { $null })
                    Controls            = $(if ($Finding.PSObject.Properties['Controls']) { $Finding.Controls } else { $null })
                    Confidence          = $(if ($Finding.PSObject.Properties['Confidence']) { $Finding.Confidence } else { $null })
                    MissingDimensions   = $(if ($Finding.PSObject.Properties['MissingDimensions']) { $Finding.MissingDimensions } else { $null })
                })
            } catch {
                $exceptionMessage = [string]$_.Exception.Message
                if (Get-Command Remove-Credentials -ErrorAction SilentlyContinue) {
                    $exceptionMessage = Remove-Credentials -Text $exceptionMessage
                }
                Write-Verbose "EntityStore metadata merge skipped for $($Finding.EntityId): $exceptionMessage"
            }

            if ($entity.Observations -isnot [System.Collections.Generic.List[pscustomobject]]) {
                $observations = [System.Collections.Generic.List[pscustomobject]]::new()
                foreach ($obs in @($entity.Observations)) {
                    if ($obs) { $observations.Add($obs) }
                }
                $entity.Observations = $observations
            }

            if (-not $entity.Observations.Contains($targetFinding)) {
                $entity.Observations.Add($targetFinding)
                $this.UpdateEntityAggregates($entity, $targetFinding)
            }
        }

        if (($this.Entities.Count + $this.Findings.Count) -gt $this.MaxEntitiesInMemory) {
            $this.SpillToDisk()
        }
    }

    [void] MergeEntityMetadata([pscustomobject] $EntityStub) {
        if (-not $EntityStub) {
            throw "EntityStub cannot be null."
        }

        $entityId = $EntityStub.EntityId ?? $EntityStub.CanonicalId
        if (-not $entityId) { throw "EntityStub must include EntityId or CanonicalId." }
        if (-not $EntityStub.EntityType) { throw "EntityStub must include EntityType." }
        if (-not $EntityStub.Platform) { throw "EntityStub must include Platform." }

        $entityKey = $this.GetEntityKey($EntityStub.Platform, $EntityStub.EntityType, $entityId)
        $entity = $this.Entities[$entityKey]
        if (-not $entity) {
            $entity = New-StoreEntity -EntityStub $EntityStub -EntityId $entityId -EntityType $EntityStub.EntityType -Platform $EntityStub.Platform
            $this.Entities[$entityKey] = $entity
            return
        }

        $entity.DisplayName = Get-NonEmptyValue $entity.DisplayName $EntityStub.DisplayName
        $entity.SubscriptionName = Get-NonEmptyValue $entity.SubscriptionName $EntityStub.SubscriptionName
        $entity.ManagementGroupPath = Get-NonEmptyValue $entity.ManagementGroupPath $EntityStub.ManagementGroupPath
        $entity.SubscriptionId = Get-NonEmptyValue $entity.SubscriptionId $EntityStub.SubscriptionId
        $entity.ResourceGroup = Get-NonEmptyValue $entity.ResourceGroup $EntityStub.ResourceGroup

        $entity.ExternalIds = Merge-UniqueByKey -Existing $entity.ExternalIds -Incoming $EntityStub.ExternalIds -KeySelector {
            param ($item) "$($item.Platform)|$($item.Id)"
        }
        $entity.Frameworks = Merge-UniqueByKey -Existing $entity.Frameworks -Incoming $EntityStub.Frameworks -KeySelector {
            param ($item) "$($item.Name)|$($item.ControlId)"
        }
        $entity.Policies = Merge-UniqueByKey -Existing $entity.Policies -Incoming $EntityStub.Policies -KeySelector {
            param ($item) "$($item.PolicyName)|$($item.AssignmentScope)"
        }

        if ($EntityStub.MonthlyCost -ne $null) { $entity.MonthlyCost = $EntityStub.MonthlyCost }
        if ($EntityStub.Currency) { $entity.Currency = $EntityStub.Currency }
        if ($EntityStub.CostTrend) { $entity.CostTrend = $EntityStub.CostTrend }

        $entity.MissingDimensions = Merge-MissingDimensions -Existing $entity.MissingDimensions -Incoming $EntityStub.MissingDimensions
    }

    [void] SpillToDisk() {
        $batch = $this.SpillFileCount
        $entitiesPath = Join-Path $this.OutputPath ("entities-partial-{0}.json" -f $batch)
        $findingsPath = Join-Path $this.OutputPath ("findings-partial-{0}.json" -f $batch)

        $entitiesJson = $this.Entities.Values | ConvertTo-Json -Depth 30
        $findingsJson = $this.Findings | ConvertTo-Json -Depth 30

        Set-Content -Path $entitiesPath -Value $entitiesJson -Encoding UTF8
        Set-Content -Path $findingsPath -Value $findingsJson -Encoding UTF8

        $this.Entities = @{}
        $this.Findings = [System.Collections.Generic.List[pscustomobject]]::new()
        $this.FindingIndex = @{}
        $this.SpillFileCount++

        Write-Warning "EntityStore exceeded $($this.MaxEntitiesInMemory) combined records, spilling batch $batch to disk. Consider scoping to fewer subscriptions."
    }

    [pscustomobject[]] GetEntities() {
        $merged = @{}

        foreach ($entity in $this.Entities.Values) {
            $key = $this.GetEntityKey($entity.Platform, $entity.EntityType, $entity.EntityId)
            $merged[$key] = $entity
        }

        if ($this.SpillFileCount -gt 0) {
            $files = Get-ChildItem -Path $this.OutputPath -Filter 'entities-partial-*.json' -ErrorAction SilentlyContinue |
                Sort-Object Name
            foreach ($file in $files) {
                $partial = Get-Content -Raw $file.FullName | ConvertFrom-Json -ErrorAction Stop
                foreach ($entity in @($partial)) {
                    $key = $this.GetEntityKey($entity.Platform, $entity.EntityType, $entity.EntityId)
                    if (-not $merged.ContainsKey($key)) {
                        $merged[$key] = $entity
                    } else {
                        $existing = $merged[$key]
                        if ($existing.Observations -is [System.Collections.Generic.List[pscustomobject]]) {
                            foreach ($obs in @($entity.Observations)) {
                                if ($obs) { $existing.Observations.Add($obs) }
                            }
                        } else {
                            $existing.Observations = @($existing.Observations) + @($entity.Observations)
                        }
                        $existing.Sources = Merge-UniqueByKey -Existing $existing.Sources -Incoming $entity.Sources -KeySelector { param ($item) $item }
                        if ((Get-SeverityRank $entity.WorstSeverity) -gt (Get-SeverityRank $existing.WorstSeverity)) {
                            $existing.WorstSeverity = $entity.WorstSeverity
                        }
                        $existing.CompliantCount = [int]($existing.CompliantCount ?? 0) + [int]($entity.CompliantCount ?? 0)
                        $existing.NonCompliantCount = [int]($existing.NonCompliantCount ?? 0) + [int]($entity.NonCompliantCount ?? 0)
                    }
                }
            }
        }

        return $merged.Values
    }

    [pscustomobject[]] GetFindings() {
        $merged = [System.Collections.Generic.List[pscustomobject]]::new()
        $index = @{}

        $allFindings = @()
        if ($this.SpillFileCount -gt 0) {
            $files = Get-ChildItem -Path $this.OutputPath -Filter 'findings-partial-*.json' -ErrorAction SilentlyContinue |
                Sort-Object Name
            foreach ($file in $files) {
                $allFindings += @(Get-Content -Raw $file.FullName | ConvertFrom-Json -ErrorAction Stop)
            }
        }
        $allFindings += @($this.Findings)

        foreach ($finding in @($allFindings)) {
            $key = $this.GetFindingKey($finding)
            if ($key -and $index.ContainsKey($key)) {
                $this.MergeFinding($index[$key], $finding)
            } else {
                $merged.Add($finding)
                if ($key) { $index[$key] = $finding }
            }
        }

        return $merged.ToArray()
    }

    [void] CleanupSpillFiles() {
        if ($this.SpillFileCount -eq 0) { return }
        Get-ChildItem -Path $this.OutputPath -Filter 'entities-partial-*.json' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Get-ChildItem -Path $this.OutputPath -Filter 'findings-partial-*.json' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        $this.SpillFileCount = 0
    }
}

function Export-Entities {
    <#
    .SYNOPSIS
        Export merged entities from an EntityStore.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [EntityStore] $Store
    )

    return $Store.GetEntities()
}

function Export-Findings {
    <#
    .SYNOPSIS
        Export merged findings from an EntityStore.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [EntityStore] $Store
    )

    return $Store.GetFindings()
}

function Export-Results {
    <#
    .SYNOPSIS
        Export v1-compatible flat findings array.
    .DESCRIPTION
        Returns the same shape as results.json. Cleans up spill files after
        merging when spill files exist.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [EntityStore] $Store
    )

    $results = $Store.GetFindings()
    $Store.CleanupSpillFiles()
    return $results
}

function New-PortfolioSeverityCounts {
    [CmdletBinding()]
    param (
        [object[]] $Findings
    )

    $relevant = @($Findings | Where-Object { $_ -and $_.PSObject.Properties['Compliant'] -and -not $_.Compliant })
    [pscustomobject]@{
        Critical = @($relevant | Where-Object { $_.Severity -eq 'Critical' }).Count
        High     = @($relevant | Where-Object { $_.Severity -eq 'High' }).Count
        Medium   = @($relevant | Where-Object { $_.Severity -eq 'Medium' }).Count
        Low      = @($relevant | Where-Object { $_.Severity -eq 'Low' }).Count
        Info     = @($relevant | Where-Object { $_.Severity -eq 'Info' }).Count
    }
}

function Resolve-SubscriptionId {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object] $InputObject
    )

    $subscriptionId = Get-ObjectPropertyValue -Object $InputObject -PropertyName 'SubscriptionId'
    if (-not [string]::IsNullOrWhiteSpace([string]$subscriptionId)) {
        return [string]$subscriptionId
    }

    foreach ($propertyName in @('ResourceId', 'EntityId')) {
        $textValue = Get-ObjectPropertyValue -Object $InputObject -PropertyName $propertyName
        if ([string]::IsNullOrWhiteSpace([string]$textValue)) { continue }
        if ([string]$textValue -match '(?i)/subscriptions/([0-9a-f-]{36})') {
            return $Matches[1].ToLowerInvariant()
        }
    }

    return $null
}

function Get-SubscriptionBucketKey {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object] $InputObject
    )

    $subscriptionId = Resolve-SubscriptionId -InputObject $InputObject
    if (-not [string]::IsNullOrWhiteSpace([string]$subscriptionId)) {
        return "id::$($subscriptionId.ToLowerInvariant())"
    }

    $subscriptionName = [string](Get-ObjectPropertyValue -Object $InputObject -PropertyName 'SubscriptionName' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($subscriptionName)) {
        return "name::$subscriptionName"
    }

    return $null
}

function Get-TopPortfolioEntities {
    [CmdletBinding()]
    param (
        [object[]] $Entities,
        [int] $MaxCount = 5
    )

    $sorted = @(
        $Entities |
            Where-Object { $_ } |
            Sort-Object `
                @{ Expression = { Get-SeverityRank (Get-ObjectPropertyValue -Object $_ -PropertyName 'WorstSeverity') }; Descending = $true }, `
                @{ Expression = { [int](Get-ObjectPropertyValue -Object $_ -PropertyName 'NonCompliantCount' -Default 0) }; Descending = $true }, `
                @{ Expression = { [double](Get-ObjectPropertyValue -Object $_ -PropertyName 'MonthlyCost' -Default 0) }; Descending = $true }, `
                @{ Expression = { [string](Get-ObjectPropertyValue -Object $_ -PropertyName 'DisplayName' -Default (Get-ObjectPropertyValue -Object $_ -PropertyName 'EntityId')) } }
    )

    return @(
        $sorted |
            Select-Object -First $MaxCount |
            ForEach-Object {
                [pscustomobject]@{
                    EntityId          = Get-ObjectPropertyValue -Object $_ -PropertyName 'EntityId'
                    EntityType        = Get-ObjectPropertyValue -Object $_ -PropertyName 'EntityType'
                    DisplayName       = Get-ObjectPropertyValue -Object $_ -PropertyName 'DisplayName' -Default (Get-ObjectPropertyValue -Object $_ -PropertyName 'EntityId')
                    WorstSeverity     = Get-ObjectPropertyValue -Object $_ -PropertyName 'WorstSeverity'
                    NonCompliantCount = [int](Get-ObjectPropertyValue -Object $_ -PropertyName 'NonCompliantCount' -Default 0)
                    MonthlyCost       = [double](Get-ObjectPropertyValue -Object $_ -PropertyName 'MonthlyCost' -Default 0)
                    Currency          = Get-ObjectPropertyValue -Object $_ -PropertyName 'Currency'
                }
            }
    )
}

function Get-PortfolioRollup {
    <#
    .SYNOPSIS
        Aggregates the current entity and finding stores into a portfolio view.
    .DESCRIPTION
        Produces subscription and management-group rollups for multi-subscription
        scans. The returned object is stable JSON-friendly shape suitable for
        portfolio.json and report rendering.
    #>
    [CmdletBinding()]
    param (
        [object] $Store,
        [object[]] $Entities,
        [object[]] $Findings,
        [string] $ManagementGroupId
    )

    if ($Store) {
        if ($null -eq $Entities -and $Store.PSObject.Methods['GetEntities']) {
            $Entities = @($Store.GetEntities())
        }
        if ($null -eq $Findings -and $Store.PSObject.Methods['GetFindings']) {
            $Findings = @($Store.GetFindings())
        }
    }

    if ($null -eq $Entities) { $Entities = @() }
    if ($null -eq $Findings) { $Findings = @() }

    $subscriptionIndex = @{}
    foreach ($item in @($Entities) + @($Findings)) {
        if (-not $item) { continue }

        $subscriptionId = Resolve-SubscriptionId -InputObject $item
        $subscriptionName = Get-ObjectPropertyValue -Object $item -PropertyName 'SubscriptionName'
        $path = @()
        $rawPath = Get-ObjectPropertyValue -Object $item -PropertyName 'ManagementGroupPath'
        if ($rawPath) { $path = @($rawPath | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) }

        if (-not $subscriptionId -and [string]::IsNullOrWhiteSpace([string]$subscriptionName)) { continue }
        $key = Get-SubscriptionBucketKey -InputObject $item
        if (-not $key) { continue }

        if (-not $subscriptionIndex.ContainsKey($key)) {
            $subscriptionIndex[$key] = [ordered]@{
                SubscriptionId      = $subscriptionId
                SubscriptionName    = if ($subscriptionName) { $subscriptionName } else { $subscriptionId }
                ManagementGroupPath = $path
            }
            continue
        }

        if (-not $subscriptionIndex[$key].SubscriptionName -and $subscriptionName) {
            $subscriptionIndex[$key].SubscriptionName = $subscriptionName
        }
        if ((@($path).Count -gt 0) -and (@($subscriptionIndex[$key].ManagementGroupPath).Count -eq 0 -or @($path).Count -gt @($subscriptionIndex[$key].ManagementGroupPath).Count)) {
            $subscriptionIndex[$key].ManagementGroupPath = $path
        }
    }

    $findingsBySubscription = @{}
    foreach ($finding in $Findings) {
        if (-not $finding -or (Get-ObjectPropertyValue -Object $finding -PropertyName 'Category') -eq 'CrossSubscriptionCorrelation') {
            continue
        }

        $bucketKey = Get-SubscriptionBucketKey -InputObject $finding
        if (-not $bucketKey) { continue }

        if (-not $findingsBySubscription.ContainsKey($bucketKey)) {
            $findingsBySubscription[$bucketKey] = [System.Collections.Generic.List[object]]::new()
        }
        $findingsBySubscription[$bucketKey].Add($finding) | Out-Null
    }

    $entitiesBySubscription = @{}
    foreach ($entity in $Entities) {
        if (-not $entity) { continue }

        $bucketKey = Get-SubscriptionBucketKey -InputObject $entity
        if (-not $bucketKey) { continue }

        if (-not $entitiesBySubscription.ContainsKey($bucketKey)) {
            $entitiesBySubscription[$bucketKey] = [System.Collections.Generic.List[object]]::new()
        }
        $entitiesBySubscription[$bucketKey].Add($entity) | Out-Null
    }

    $subscriptionRows = [System.Collections.Generic.List[object]]::new()
    foreach ($bucketKey in $subscriptionIndex.Keys) {
        $entry = $subscriptionIndex[$bucketKey]
        $subId = $entry.SubscriptionId
        $subName = if ($entry.SubscriptionName) { $entry.SubscriptionName } elseif ($subId) { $subId } else { 'unknown-subscription' }
        $subFindings = if ($findingsBySubscription.ContainsKey($bucketKey)) { @($findingsBySubscription[$bucketKey]) } else { @() }
        $subEntities = if ($entitiesBySubscription.ContainsKey($bucketKey)) { @($entitiesBySubscription[$bucketKey]) } else { @() }

        $severityCounts = New-PortfolioSeverityCounts -Findings $subFindings
        $sourceCounts = @(
            $subFindings |
                Where-Object { $_ -and $_.PSObject.Properties['Compliant'] -and -not $_.Compliant } |
                Group-Object -Property Source |
                Sort-Object `
                    @{ Expression = 'Count'; Descending = $true }, `
                    @{ Expression = 'Name' } |
                ForEach-Object {
                    [pscustomobject]@{
                        Source = $_.Name
                        Count  = $_.Count
                    }
                }
        )

        $monthlyCost = [double]0
        $currency = ''
        foreach ($entity in $subEntities) {
            $cost = Get-ObjectPropertyValue -Object $entity -PropertyName 'MonthlyCost'
            if ($null -ne $cost -and "$cost" -ne '') {
                $monthlyCost += [double]$cost
            }
            if (-not $currency) {
                $currency = [string](Get-ObjectPropertyValue -Object $entity -PropertyName 'Currency' -Default '')
            }
        }

        $worstSeverity = 'Info'
        foreach ($level in @('Critical', 'High', 'Medium', 'Low', 'Info')) {
            if ([int]$severityCounts.$level -gt 0) {
                $worstSeverity = $level
                break
            }
        }

        $subscriptionRows.Add([pscustomobject]@{
                SubscriptionId      = $subId
                SubscriptionName    = $subName
                ManagementGroupPath = @($entry.ManagementGroupPath)
                FindingCount        = @($subFindings).Count
                NonCompliantCount   = @($subFindings | Where-Object { $_ -and $_.PSObject.Properties['Compliant'] -and -not $_.Compliant }).Count
                SeverityCounts      = $severityCounts
                SourceCounts        = $sourceCounts
                TopEntities         = @(Get-TopPortfolioEntities -Entities $subEntities)
                MonthlyCost         = [math]::Round($monthlyCost, 2)
                Currency            = $currency
                WorstSeverity       = $worstSeverity
            }) | Out-Null
    }

    $subscriptionRows = @(
        $subscriptionRows |
            Sort-Object `
                @{ Expression = { Get-SeverityRank $_.WorstSeverity }; Descending = $true }, `
                @{ Expression = { [int]$_.NonCompliantCount }; Descending = $true }, `
                @{ Expression = { [string]$_.SubscriptionName } }
    )

    $managementGroupBuckets = @{}
    foreach ($row in $subscriptionRows) {
        $path = @($row.ManagementGroupPath)
        if ($path.Count -eq 0) {
            if ($ManagementGroupId) {
                $path = @($ManagementGroupId)
            } else {
                continue
            }
        }

        $key = $path -join ' > '
        if (-not $managementGroupBuckets.ContainsKey($key)) {
            $managementGroupBuckets[$key] = [System.Collections.Generic.List[object]]::new()
        }
        $managementGroupBuckets[$key].Add($row) | Out-Null
    }

    $managementGroupRows = [System.Collections.Generic.List[object]]::new()
    foreach ($bucketKey in $managementGroupBuckets.Keys) {
        $rows = @($managementGroupBuckets[$bucketKey])
        $mgPath = if ($rows.Count -gt 0) { @($rows[0].ManagementGroupPath) } else { @($ManagementGroupId) }
        $criticalCount = 0
        $highCount = 0
        $mediumCount = 0
        $lowCount = 0
        $infoCount = 0
        foreach ($row in $rows) {
            $criticalCount += [int]$row.SeverityCounts.Critical
            $highCount += [int]$row.SeverityCounts.High
            $mediumCount += [int]$row.SeverityCounts.Medium
            $lowCount += [int]$row.SeverityCounts.Low
            $infoCount += [int]$row.SeverityCounts.Info
        }
        $severityCounts = [pscustomobject]@{
            Critical = $criticalCount
            High     = $highCount
            Medium   = $mediumCount
            Low      = $lowCount
            Info     = $infoCount
        }

        $managementGroupRows.Add([pscustomobject]@{
                ManagementGroupName = if ($mgPath.Count -gt 0) { $mgPath[-1] } elseif ($ManagementGroupId) { $ManagementGroupId } else { 'portfolio' }
                ManagementGroupPath = $mgPath
                SubscriptionCount   = $rows.Count
                NonCompliantCount   = (@($rows | Measure-Object -Property NonCompliantCount -Sum).Sum ?? 0)
                SeverityCounts      = $severityCounts
                MonthlyCost         = [math]::Round((@($rows | Measure-Object -Property MonthlyCost -Sum).Sum ?? 0), 2)
                Currency            = [string]($rows | ForEach-Object { $_.Currency } | Where-Object { $_ } | Select-Object -First 1)
            }) | Out-Null
    }

    $correlations = @(
        $Findings |
            Where-Object {
                $_ -and
                $_.Source -eq 'identity-correlator' -and
                $_.Category -eq 'CrossSubscriptionCorrelation'
            } |
            Sort-Object `
                @{ Expression = { Get-SeverityRank $_.Severity }; Descending = $true }, `
                @{ Expression = { [string]$_.Title } }
    )

    return [pscustomobject]@{
        SchemaVersion = '1.0'
        GeneratedAt   = (Get-Date).ToUniversalTime().ToString('o')
        Summary       = [pscustomobject]@{
            ManagementGroupId  = $ManagementGroupId
            SubscriptionCount  = @($subscriptionRows).Count
            ManagementGroupCount = @($managementGroupRows).Count
            CorrelationCount   = @($correlations).Count
            TotalFindings      = @($Findings).Count
            TotalNonCompliant  = @($Findings | Where-Object { $_ -and $_.PSObject.Properties['Compliant'] -and -not $_.Compliant }).Count
        }
        Subscriptions = $subscriptionRows
        ManagementGroups = @($managementGroupRows)
        Correlations  = $correlations
    }
}
