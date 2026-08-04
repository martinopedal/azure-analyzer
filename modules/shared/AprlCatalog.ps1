#Requires -Version 7.0
<#
.SYNOPSIS
    APRL recommendation-catalog helpers for enriching WARA findings.
.DESCRIPTION
    The WARA collector emits APRL reliability findings whose title, severity,
    detail and learn-more link are not always present on the raw record; those
    findings would otherwise ship with Title = 'Unknown'. Each finding still
    carries the APRL recommendation GUID (as RecommendationId, and as the first
    segment of Id when split on '::'). Joining that GUID to the APRL
    recommendation catalog recovers the missing metadata.

    Merge-WaraAprlMetadata is a pure, offline function: it takes a findings list
    and a catalog hashtable and backfills only findings that are still 'Unknown'.
    Get-WaraAprlCatalog is a best-effort, HTTPS-only loader that degrades to
    $null on any failure, so the wrapper has no hard network dependency.
#>

Set-StrictMode -Version Latest

function Get-AprlPropertyValue {
    param(
        [object] $Object,
        [Parameter(Mandatory)][string[]] $Names
    )
    if ($null -eq $Object) { return $null }
    foreach ($name in $Names) {
        $prop = $Object.PSObject.Properties[$name]
        if ($prop -and $null -ne $prop.Value) {
            if ($prop.Value -is [string]) {
                if (-not [string]::IsNullOrWhiteSpace($prop.Value)) { return $prop.Value }
            } else {
                return $prop.Value
            }
        }
    }
    return $null
}

function Set-AprlFindingProperty {
    param(
        [Parameter(Mandatory)][object] $Finding,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][AllowEmptyString()][object] $Value
    )
    if ($Finding.PSObject.Properties[$Name]) {
        $Finding.$Name = $Value
    } else {
        Add-Member -InputObject $Finding -MemberType NoteProperty -Name $Name -Value $Value -Force
    }
}

function ConvertTo-AprlSeverity {
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    switch -Regex ($Value.Trim().ToLowerInvariant()) {
        '^crit'             { return 'Critical' }
        '^high$'            { return 'High' }
        '^med'              { return 'Medium' }
        '^low$'             { return 'Low' }
        '^info'             { return 'Info' }
        default             { return 'Medium' }
    }
}

function Test-AprlSafeUrl {
    <#
    .SYNOPSIS
        Returns $true only for absolute HTTPS URLs.
    .DESCRIPTION
        Catalog-sourced links are rendered into the HTML report as clickable
        <a href='...'> targets. The report HTML-encodes the value, which stops
        attribute breakout but does NOT stop a hostile scheme: 'javascript:...'
        contains no encodable characters and stays live on click. Enforcing the
        repo's HTTPS-only invariant at ingest is the reliable place to stop it.
    #>
    param([string] $Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    $uri = $null
    if (-not [System.Uri]::TryCreate($Url.Trim(), [System.UriKind]::Absolute, [ref]$uri)) { return $false }
    return ($uri.Scheme -eq 'https')
}

function Get-AprlDefaultCachePath {
    <#
    .SYNOPSIS
        User-scoped cache path for the APRL catalog.
    .DESCRIPTION
        Deliberately NOT the shared temp directory. Other temp files in this repo
        are write-then-read within a single run and carry a random GUID in the
        name; this cache is the opposite - a stable, predictable path that a
        later run reads back and trusts. On Linux/macOS the shared temp dir is
        world-writable, so a predictable name there lets any local user
        pre-create the file and choose the titles, details and links that land
        in the report. LocalApplicationData is user-scoped and removes that.
    #>
    $root = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($root)) { $root = [System.IO.Path]::GetTempPath() }
    return (Join-Path (Join-Path $root 'azure-analyzer') 'wara-aprl-catalog.json')
}

function Get-AprlLearnMoreUrl {
    param([object] $Record)
    if ($null -eq $Record) { return '' }
    $link = Get-AprlPropertyValue -Object $Record -Names @('learnMoreLink', 'learnMoreUrl', 'learnMore')
    if ($null -eq $link) { return '' }
    $candidate = ''
    if ($link -is [string]) {
        $candidate = $link
    } else {
        $first = @($link) | Select-Object -First 1
        if ($null -eq $first) { return '' }
        if ($first -is [string]) {
            $candidate = $first
        } else {
            $candidate = [string](Get-AprlPropertyValue -Object $first -Names @('url', 'href', 'link'))
        }
    }
    if (-not (Test-AprlSafeUrl $candidate)) { return '' }
    return $candidate.Trim()
}

function ConvertTo-WaraAprlCatalog {
    <#
    .SYNOPSIS
        Builds a GUID-keyed hashtable from an array of APRL recommendation records.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][object[]] $Records
    )
    $catalog = @{}
    if ($null -eq $Records) { return $catalog }
    foreach ($record in $Records) {
        if ($null -eq $record) { continue }
        $guid = [string](Get-AprlPropertyValue -Object $record -Names @('aprlGuid', 'recommendationId', 'guid', 'id'))
        if ([string]::IsNullOrWhiteSpace($guid)) { continue }
        $catalog[$guid.Trim().ToLowerInvariant()] = $record
    }
    return $catalog
}

function Get-WaraAprlCatalog {
    <#
    .SYNOPSIS
        Loads the APRL recommendation catalog (cache first, then optional fetch).
    .DESCRIPTION
        Best-effort and offline-safe. Returns a GUID-keyed hashtable, or $null if
        no catalog could be loaded. Only HTTPS URLs are fetched.

        The cache is treated as valid only while it is younger than MaxAgeHours.
        APRL publishes new recommendation GUIDs continuously, so an unbounded
        cache would permanently fail to resolve every GUID added after the first
        successful fetch - the enrichment would silently rot instead of failing.
        A stale cache is still kept as a fallback: if the refresh fetch fails we
        prefer stale metadata over no metadata.
    #>
    [CmdletBinding()]
    param(
        [string] $Path,
        [string] $Url = 'https://azure.github.io/WARA-Build/objects/recommendations.json',
        [int] $MaxAgeHours = 168,
        [switch] $Refresh
    )

    $records = $null
    $staleRecords = $null

    if ($Path -and (Test-Path $Path) -and -not $Refresh) {
        try {
            $cached = Get-Content -Path $Path -Raw | ConvertFrom-Json
            $ageHours = ([DateTime]::UtcNow - (Get-Item -LiteralPath $Path).LastWriteTimeUtc).TotalHours
            if ($MaxAgeHours -le 0 -or $ageHours -le $MaxAgeHours) {
                $records = $cached
            } else {
                $staleRecords = $cached
                Write-Verbose ("APRL catalog cache is {0:N0}h old (max {1}h); refreshing." -f $ageHours, $MaxAgeHours)
            }
        } catch { $records = $null }
    }

    if ($null -eq $records -and -not [string]::IsNullOrWhiteSpace($Url)) {
        if ($Url -notmatch '^https://') { return $null }
        try {
            $fetch = { Invoke-RestMethod -Uri $Url -Method Get -TimeoutSec 30 -ErrorAction Stop }
            if (Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue) {
                $records = Invoke-WithRetry -ScriptBlock $fetch -MaxAttempts 3 -InitialDelaySeconds 2
            } else {
                $records = & $fetch
            }
            if ($Path) {
                try {
                    $parent = Split-Path -Parent $Path
                    if ($parent -and -not (Test-Path $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
                    $records | ConvertTo-Json -Depth 12 | Set-Content -Path $Path -Encoding UTF8
                } catch { Write-Verbose "APRL catalog cache write skipped: $([string]$_)" }
            }
        } catch {
            Write-Verbose "APRL catalog fetch failed: $([string]$_)"
            $records = $staleRecords
        }
    }

    if ($null -eq $records) { return $null }
    return ConvertTo-WaraAprlCatalog -Records @($records)
}

function Merge-WaraAprlMetadata {
    <#
    .SYNOPSIS
        Backfills Title/Severity/Detail/LearnMoreUrl on WARA findings from the APRL catalog.
    .DESCRIPTION
        Pure and offline. Only findings whose Title is empty or 'Unknown' are
        touched, so existing good metadata is never clobbered. The APRL GUID is
        read from RecommendationId, falling back to the first '::' segment of Id.
        Returns the same findings collection for convenience.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object] $Findings,
        [Parameter(Mandatory)][hashtable] $Catalog
    )

    if ($null -eq $Findings -or $null -eq $Catalog -or $Catalog.Count -eq 0) { return $Findings }

    foreach ($finding in @($Findings)) {
        if ($null -eq $finding) { continue }

        $title = [string](Get-AprlPropertyValue -Object $finding -Names @('Title'))
        $needsEnrichment = [string]::IsNullOrWhiteSpace($title) -or $title -eq 'Unknown'
        if (-not $needsEnrichment) { continue }

        $guid = [string](Get-AprlPropertyValue -Object $finding -Names @('RecommendationId'))
        if ([string]::IsNullOrWhiteSpace($guid)) {
            $idValue = [string](Get-AprlPropertyValue -Object $finding -Names @('Id'))
            if (-not [string]::IsNullOrWhiteSpace($idValue)) { $guid = ($idValue -split '::')[0] }
        }
        if ([string]::IsNullOrWhiteSpace($guid)) { continue }

        $key = $guid.Trim().ToLowerInvariant()
        if (-not $Catalog.ContainsKey($key)) { continue }
        $record = $Catalog[$key]

        $catalogTitle = [string](Get-AprlPropertyValue -Object $record -Names @('description', 'title', 'recommendationTitle'))
        if (-not [string]::IsNullOrWhiteSpace($catalogTitle)) {
            Set-AprlFindingProperty -Finding $finding -Name 'Title' -Value $catalogTitle
        }

        $catalogSeverity = ConvertTo-AprlSeverity ([string](Get-AprlPropertyValue -Object $record -Names @('recommendationImpact', 'impact', 'severity')))
        if (-not [string]::IsNullOrWhiteSpace($catalogSeverity)) {
            Set-AprlFindingProperty -Finding $finding -Name 'Severity' -Value $catalogSeverity
        }

        $existingDetail = [string](Get-AprlPropertyValue -Object $finding -Names @('Detail'))
        $catalogDetail = [string](Get-AprlPropertyValue -Object $record -Names @('longDescription', 'description'))
        if ([string]::IsNullOrWhiteSpace($existingDetail) -and -not [string]::IsNullOrWhiteSpace($catalogDetail)) {
            Set-AprlFindingProperty -Finding $finding -Name 'Detail' -Value $catalogDetail
        }

        $existingUrl = [string](Get-AprlPropertyValue -Object $finding -Names @('LearnMoreUrl'))
        if ([string]::IsNullOrWhiteSpace($existingUrl)) {
            $catalogUrl = Get-AprlLearnMoreUrl -Record $record
            if (-not [string]::IsNullOrWhiteSpace($catalogUrl)) {
                Set-AprlFindingProperty -Finding $finding -Name 'LearnMoreUrl' -Value $catalogUrl
                Set-AprlFindingProperty -Finding $finding -Name 'DeepLinkUrl' -Value $catalogUrl
            }
        }
    }

    return $Findings
}
