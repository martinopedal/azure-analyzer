#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('Small', 'Medium', 'Large')]
    [string] $Size = 'Small',
    [switch] $GraphHeavy,
    [string] $OutputDir = '',
    [int] $Seed = 42
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-SyntheticFixtureCount {
    param([Parameter(Mandatory)][ValidateSet('Small', 'Medium', 'Large')][string]$Size)
    switch ($Size) {
        'Small' { return 10000 }
        'Medium' { return 100000 }
        'Large' { return 500000 }
    }
}

function New-SyntheticFixture {
    [CmdletBinding()]
    param(
        [ValidateSet('Small', 'Medium', 'Large')]
        [string] $Size = 'Small',
        [switch] $GraphHeavy,
        [Parameter(Mandatory)]
        [string] $OutputDir,
        [int] $Seed = 42
    )

    $count = Resolve-SyntheticFixtureCount -Size $Size
    $rng = [System.Random]::new($Seed)

    if (-not (Test-Path $OutputDir)) {
        $null = New-Item -ItemType Directory -Path $OutputDir -Force
    }

    $severities = @('Critical', 'High', 'Medium', 'Low', 'Info')
    $findings = [System.Collections.Generic.List[object]]::new()
    $entities = [System.Collections.Generic.List[object]]::new()
    $edges = [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $count; $i++) {
        $subGuid = ('{0:x8}-{1:x4}-{2:x4}-{3:x4}-{4:x12}' -f $rng.Next(), $rng.Next(0,65535), $rng.Next(0,65535), $rng.Next(0,65535), $rng.Next(0,2147483647))
        $entityId = "/subscriptions/$subGuid/resourcegroups/rg-$($i % 50)/providers/microsoft.compute/virtualmachines/vm-$i".ToLowerInvariant()
        $severity = $severities[$i % $severities.Count]

        $findings.Add([pscustomobject]@{
            Id                 = "synthetic-$i"
            Source             = 'synthetic'
            Category           = 'Foundation'
            Title              = "Synthetic finding $i"
            Severity           = $severity
            Compliant          = ($i % 4 -eq 0)
            Detail             = "Synthetic detail $i"
            Remediation        = 'Use baseline policy'
            ResourceId         = $entityId
            LearnMoreUrl       = 'https://learn.microsoft.com/azure/'
            EntityId           = $entityId
            EntityType         = 'AzureResource'
            Platform           = 'Azure'
            SubscriptionId     = ($subGuid.ToLowerInvariant())
            SubscriptionName   = "sub-$($i % 20)"
            ResourceGroup      = "rg-$($i % 50)"
            ManagementGroupPath = @('root', "mg-$($i % 4)")
            Confidence         = 'Likely'
            EvidenceCount      = 1
            MissingDimensions  = @()
            DocsUrl            = 'https://learn.microsoft.com/azure/well-architected/'
            RemediationScript  = 'az policy assignment create --name synthetic'
            ComplianceMappings = @([pscustomobject]@{ framework = 'CIS'; control = '1.1.1'; version = '1.4.0' })
            RuleReference      = "SYN-$($i % 25)"
            SeverityRationale  = "Pattern score for $severity"
            AffectedProperties = @('identity.type', 'networkProfile')
            ToolVersion        = 'synthetic-1.0.0'
            SuggestedPolicies  = @([pscustomobject]@{ source = 'AzAdvertizer'; policyId = "/providers/microsoft.authorization/policydefinitions/syn-$($i % 10)"; docsUrl = 'https://www.azadvertizer.net/' })
            SchemaVersion      = '2.2'
        }) | Out-Null

        $entities.Add([pscustomobject]@{
            EntityId          = $entityId
            EntityType        = 'AzureResource'
            Platform          = 'Azure'
            DisplayName       = "vm-$i"
            SubscriptionId    = ($subGuid.ToLowerInvariant())
            SubscriptionName  = "sub-$($i % 20)"
            ResourceGroup     = "rg-$($i % 50)"
            Observations      = @()
            WorstSeverity     = $severity
            CompliantCount    = if ($i % 4 -eq 0) { 1 } else { 0 }
            NonCompliantCount = if ($i % 4 -eq 0) { 0 } else { 1 }
            Sources           = @('synthetic')
        }) | Out-Null
    }

    $edgeRelations = @('TriggeredBy','DependsOn','PolicyAssignedTo','PolicyEnforces','FailsOverTo','ReplicatedTo','DeploysTo','UsesSecret')
    if ($GraphHeavy) {
        $edgeCount = [Math]::Max(3000, [int]($count / 3))
        for ($i = 0; $i -lt $edgeCount; $i++) {
            $sourceIndex = $i % $count
            $targetIndex = ($i * 7) % $count
            $sourceId = "/subscriptions/syn-sub/resourcegroups/rg-$($sourceIndex % 50)/providers/microsoft.compute/virtualmachines/vm-$sourceIndex".ToLowerInvariant()
            $targetId = "/subscriptions/syn-sub/resourcegroups/rg-$($targetIndex % 50)/providers/microsoft.compute/virtualmachines/vm-$targetIndex".ToLowerInvariant()
            $relation = $edgeRelations[$i % $edgeRelations.Count]
            $edges.Add([pscustomobject]@{
                EdgeId        = "edge:$sourceId|$relation|$targetId"
                Source        = $sourceId
                Target        = $targetId
                Relation      = $relation
                Properties    = [pscustomobject]@{ attackPath = ($relation -eq 'TriggeredBy'); resilience = ($relation -in @('FailsOverTo', 'ReplicatedTo')); policy = ($relation -like 'Policy*') }
                Confidence    = 'Likely'
                Platform      = 'Azure'
                DiscoveredBy  = 'synthetic-fixture'
                DiscoveredAt  = '2026-01-01T00:00:00Z'
                SchemaVersion = '3.1'
            }) | Out-Null
        }
    }

    $entitiesPayload = [pscustomobject]@{
        SchemaVersion = '3.1'
        Entities      = @($entities)
        Edges         = @($edges)
    }

    Set-Content -Path (Join-Path $OutputDir 'findings.json') -Value (@($findings) | ConvertTo-Json -Depth 20) -Encoding UTF8
    Set-Content -Path (Join-Path $OutputDir 'entities.json') -Value ($entitiesPayload | ConvertTo-Json -Depth 20) -Encoding UTF8
    Set-Content -Path (Join-Path $OutputDir 'edges.json') -Value (@($edges) | ConvertTo-Json -Depth 20) -Encoding UTF8
}

if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($OutputDir)) {
        throw "OutputDir is required when invoking Generate-SyntheticFixture.ps1 directly."
    }
    New-SyntheticFixture -Size $Size -GraphHeavy:$GraphHeavy -OutputDir $OutputDir -Seed $Seed
}
