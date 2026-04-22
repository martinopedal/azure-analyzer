#Requires -Version 7.4
<#
.SYNOPSIS
    Deterministic synthetic FindingRow / entity / edge fixture generator.
.DESCRIPTION
    Phase 0 (#435) shared fixture factory used by every downstream track for
    tier-specific smoke tests. Outputs are byte-deterministic given the same
    -Seed so Pester can compare against golden files without flake.

    The generator emits three artefacts under -OutputRoot:
      * findings.json   - array of FindingRow v2.x objects
      * entities.json   - { SchemaVersion, Entities[], Edges[] }
      * manifest.json   - sizing metadata (counts, seed, tier hint)

    Counts are tunable so callers can build the canonical 10k / 100k / 500k
    finding-size fixtures plus graph-heavy variants (-EdgeCount large enough
    to push the picker into PodeViewer).
.PARAMETER OutputRoot
    Directory the three artefact files will be written to. Created if missing.
.PARAMETER Seed
    Integer seed for the deterministic PRNG. Same seed + same counts yields
    byte-identical output.
.PARAMETER FindingCount
    Number of FindingRow objects to emit.
.PARAMETER EntityCount
    Number of entity stubs to emit. Defaults to FindingCount/4 (rounded up,
    minimum 1) so every entity is referenced by ~4 findings.
.PARAMETER EdgeCount
    Number of edges to emit between entities. Defaults to EntityCount.
.PARAMETER Tier
    Optional tier label written into manifest.json for downstream test
    selection. Free-form string.
.EXAMPLE
    Generate-SyntheticFixture.ps1 -OutputRoot tests/fixtures/phase0/small -Seed 1 -FindingCount 100
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $OutputRoot,
    [int] $Seed = 1,
    [Parameter(Mandatory)][int] $FindingCount,
    [int] $EntityCount = 0,
    [int] $EdgeCount = 0,
    [string] $Tier = 'PureJson'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($FindingCount -lt 0) { throw "FindingCount must be >= 0 (received $FindingCount)." }
if ($EntityCount -eq 0) { $EntityCount = [int][math]::Max(1, [math]::Ceiling($FindingCount / 4.0)) }
if ($EdgeCount -eq 0) { $EdgeCount = $EntityCount }

if (-not (Test-Path -LiteralPath $OutputRoot)) {
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
}

# Deterministic PRNG: System.Random is seedable and stable across PS versions.
$rng = [System.Random]::new($Seed)

$severities  = @('Critical','High','Medium','Low','Info')
$entityTypes = @('AzureResource','ServicePrincipal','Subscription','Tenant','Repository','Workflow')
$platforms   = @('Azure','Entra','GitHub','ADO','IaC')
$relations   = @('GuestOf','MemberOf','HasRoleOn','DependsOn','RegionPinned','PolicyAssignedTo','TriggeredBy','UsesSecret')
$confidences = @('Confirmed','Likely','Unconfirmed','Unknown')

function Get-RandomItem {
    param([object[]] $Items)
    return $Items[$rng.Next(0, $Items.Count)]
}

# ----- entities -----
$entities = New-Object 'System.Collections.Generic.List[psobject]'
for ($i = 0; $i -lt $EntityCount; $i++) {
    $etype = Get-RandomItem $entityTypes
    $entities.Add([pscustomobject]@{
        EntityId      = "synthetic:$etype/$i"
        EntityType    = $etype
        Platform      = Get-RandomItem $platforms
        DisplayName   = "synthetic-$etype-$i"
        Properties    = [pscustomobject]@{ index = $i }
        SchemaVersion = '3.1'
    }) | Out-Null
}

# ----- edges -----
$edges = New-Object 'System.Collections.Generic.List[psobject]'
if ($EntityCount -ge 2) {
    for ($i = 0; $i -lt $EdgeCount; $i++) {
        $srcIdx = $rng.Next(0, $EntityCount)
        $tgtIdx = $rng.Next(0, $EntityCount)
        if ($srcIdx -eq $tgtIdx) { $tgtIdx = ($tgtIdx + 1) % $EntityCount }
        $relation = Get-RandomItem $relations
        $src = $entities[$srcIdx].EntityId
        $tgt = $entities[$tgtIdx].EntityId
        $edges.Add([pscustomobject]@{
            EdgeId        = "edge:$($src.ToLowerInvariant())|$relation|$($tgt.ToLowerInvariant())"
            Source        = $src.ToLowerInvariant()
            Target        = $tgt.ToLowerInvariant()
            Relation      = $relation
            Properties    = [pscustomobject]@{ synthetic = $true }
            Confidence    = Get-RandomItem $confidences
            Platform      = Get-RandomItem $platforms
            DiscoveredBy  = 'synthetic-fixture-generator'
            DiscoveredAt  = '2026-01-01T00:00:00.0000000Z'
            SchemaVersion = '3.1'
        }) | Out-Null
    }
}

# ----- findings -----
$findings = New-Object 'System.Collections.Generic.List[psobject]'
for ($i = 0; $i -lt $FindingCount; $i++) {
    $entity = $entities[$rng.Next(0, [math]::Max(1, $EntityCount))]
    $sev = Get-RandomItem $severities
    $findings.Add([pscustomobject]@{
        Id               = "synthetic-finding-$i"
        Source           = 'synthetic'
        Category         = 'Synthetic'
        Title            = "Synthetic finding $i"
        RuleId           = "Synthetic.Rule.$($i % 50)"
        Severity         = $sev
        Compliant        = ($sev -eq 'Info')
        Detail           = "Generated detail for finding $i."
        Remediation      = ''
        ResourceId       = $entity.EntityId
        LearnMoreUrl     = ''
        EntityId         = $entity.EntityId
        EntityType       = $entity.EntityType
        Platform         = $entity.Platform
        Provenance       = [pscustomobject]@{
            RunId        = "synthetic-run-$Seed"
            Source       = 'synthetic'
            RawRecordRef = ''
            Timestamp    = '2026-01-01T00:00:00.0000000Z'
        }
        SchemaVersion    = '2.2'
    }) | Out-Null
}

# ----- write artefacts -----
$findingsPath = Join-Path $OutputRoot 'findings.json'
$entitiesPath = Join-Path $OutputRoot 'entities.json'
$manifestPath = Join-Path $OutputRoot 'manifest.json'

$findings.ToArray() | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $findingsPath -Encoding utf8
([pscustomobject]@{
    SchemaVersion = '3.1'
    Entities      = $entities.ToArray()
    Edges         = $edges.ToArray()
}) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $entitiesPath -Encoding utf8
([pscustomobject]@{
    Seed         = $Seed
    Tier         = $Tier
    Counts       = [pscustomobject]@{
        Findings = $findings.Count
        Entities = $entities.Count
        Edges    = $edges.Count
    }
    GeneratedBy  = 'tests/fixtures/Generate-SyntheticFixture.ps1'
    GeneratedAt  = '2026-01-01T00:00:00.0000000Z'
}) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding utf8

return [pscustomobject]@{
    OutputRoot   = (Resolve-Path -LiteralPath $OutputRoot).Path
    FindingsPath = $findingsPath
    EntitiesPath = $entitiesPath
    ManifestPath = $manifestPath
    Seed         = $Seed
    Counts       = [pscustomobject]@{
        Findings = $findings.Count
        Entities = $entities.Count
        Edges    = $edges.Count
    }
}
