#Requires -Version 7.4
<#
.SYNOPSIS
    Map an EASM-discovered IP or hostname back to a canonical Azure entity.
.DESCRIPTION
    EASM tools (Shodan, Censys, Amass, Subfinder, httpx, DnsTwist,
    Defender EASM) discover internet-reachable assets. Each finding has
    one of:

      * A public IP address.
      * A hostname / FQDN.
      * Both.

    Resolve-EasmEntity tries to map the asset back to an existing
    AzureResource (typically a Public IP, Front Door, App Gateway,
    API Management, Storage public endpoint, AKS load balancer) using
    the entity inventory the orchestrator already builds. When a match
    is found, the resulting FindingRow is anchored to the AzureResource
    so the auditor report and attack-path visualizer thread the EASM
    finding through the existing graph.

    When no match is found, the asset is treated as an ExternalAsset
    (new EntityType in Schema.ps1 v2.2) on Platform 'External'. Auditors
    see these in an "unverified ownership" bucket and can dismiss them
    if the operator never seeded them.

    The lookup is intentionally exact-match-only (case-insensitive). We
    do not do fuzzy matching: returning the wrong AzureResource ID would
    silently misroute a finding.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-EasmEntityIndex {
    <#
    .SYNOPSIS
        Build a fast lookup index from an entities.json snapshot.
    .PARAMETER Entities
        Array of entity records, typically loaded from the orchestrator's
        in-memory EntityStore or from entities.json on disk.
    .OUTPUTS
        Hashtable with two keys:
          * Ips  -> Dictionary<string, EntityRecord>
          * Hosts -> Dictionary<string, EntityRecord>
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Entities
    )

    $ips   = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $hosts = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($entity in $Entities) {
        if ($null -eq $entity) { continue }
        if (-not $entity.PSObject.Properties['EntityType']) { continue }
        if ($entity.EntityType -ne 'AzureResource') { continue }

        $attrs = $null
        if ($entity.PSObject.Properties['Attributes']) { $attrs = $entity.Attributes }
        if ($null -eq $attrs) { continue }

        # Public-IP slot. Defender for Cloud / ARG inventory typically
        # surfaces this as Attributes.PublicIp or Attributes.IpAddress.
        foreach ($prop in @('PublicIp', 'IpAddress', 'Ip')) {
            if (-not $attrs.PSObject.Properties[$prop]) { continue }
            $val = $attrs.$prop
            if ([string]::IsNullOrWhiteSpace([string]$val)) { continue }
            $key = ([string]$val).Trim()
            if (-not $ips.ContainsKey($key)) { $ips[$key] = $entity }
        }

        # Hostname / FQDN slots. Front Door / App Gateway / API Management
        # surface FQDNs at varying property names.
        foreach ($prop in @('Hostname', 'Fqdn', 'HostName', 'FrontendFqdn', 'PublicFqdn')) {
            if (-not $attrs.PSObject.Properties[$prop]) { continue }
            $val = $attrs.$prop
            if ([string]::IsNullOrWhiteSpace([string]$val)) { continue }
            $key = ([string]$val).Trim().TrimEnd('.').ToLowerInvariant()
            if (-not $hosts.ContainsKey($key)) { $hosts[$key] = $entity }
        }
    }

    return @{ Ips = $ips; Hosts = $hosts }
}

function Resolve-EasmEntity {
    <#
    .SYNOPSIS
        Map an EASM-discovered IP / host to a canonical entity.
    .PARAMETER Index
        Lookup index from Get-EasmEntityIndex.
    .PARAMETER Ip
        Optional IP string from the EASM finding.
    .PARAMETER HostName
        Optional hostname / FQDN from the EASM finding.
    .OUTPUTS
        PSCustomObject with EntityId, EntityType, Platform,
        Confidence, MatchedOn (one of 'ip', 'host', 'none').
    .NOTES
        Returns ExternalAsset / External when no match is found. The
        EntityId is then derived from whichever input was supplied
        (host preferred over IP for human readability).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [hashtable] $Index,

        [string] $Ip,

        [Alias('Host', 'Fqdn')]
        [string] $HostName
    )

    $hostKey = if ($HostName) { $HostName.Trim().TrimEnd('.').ToLowerInvariant() } else { '' }
    $ipKey   = if ($Ip)   { $Ip.Trim() } else { '' }

    if ($hostKey -and $Index.Hosts.ContainsKey($hostKey)) {
        $entity = $Index.Hosts[$hostKey]
        return [PSCustomObject]@{
            EntityId   = [string]$entity.EntityId
            EntityType = 'AzureResource'
            Platform   = 'Azure'
            Confidence = 'Confirmed'
            MatchedOn  = 'host'
        }
    }

    if ($ipKey -and $Index.Ips.ContainsKey($ipKey)) {
        $entity = $Index.Ips[$ipKey]
        return [PSCustomObject]@{
            EntityId   = [string]$entity.EntityId
            EntityType = 'AzureResource'
            Platform   = 'Azure'
            Confidence = 'Confirmed'
            MatchedOn  = 'ip'
        }
    }

    # Fallback: ExternalAsset. Prefer host as the EntityId when present
    # (human-readable), otherwise IP, otherwise a stable placeholder.
    $externalId = if ($hostKey) { "host:$hostKey" }
                  elseif ($ipKey) { "ip:$ipKey" }
                  else { 'external:unknown' }

    return [PSCustomObject]@{
        EntityId   = $externalId
        EntityType = 'ExternalAsset'
        Platform   = 'External'
        Confidence = 'Unconfirmed'
        MatchedOn  = 'none'
    }
}
