#Requires -Version 7.4
<#
.SYNOPSIS
    Build the EASM seed bundle used by every EASM wrapper.
.DESCRIPTION
    EASM wrappers (Shodan, Censys, Amass, Subfinder, httpx, DnsTwist,
    Defender EASM) all need the same input: a normalised set of domains,
    IPs, CIDRs, and ASNs that bound what we are willing to scan.

    Get-EasmSeed merges three sources, in priority order:

      1. Operator-supplied -SeedFile (JSON: { domains:[], ips:[],
         cidrs:[], asns:[] }) or -Seed hashtable.
      2. Optional ARG augmentation (public IPs, Front Door / App Gateway
         frontends). Stubbed in this revision; populated by the live
         orchestrator path.
      3. Optional Entra augmentation (verified domains). Stubbed in this
         revision; populated by the live orchestrator path.

    The output is a deterministic PSCustomObject with Domains, Ips,
    Cidrs, Asns (sorted, lower-cased, de-duplicated), plus a stable
    SHA-256 Hash that wrappers can use as a cache-invalidation key.

    Security: input strings are length-bounded and pattern-validated so
    a malicious seed file cannot smuggle shell metacharacters into a
    downstream CLI invocation. Anything that fails validation is
    discarded with a warning, never echoed back into the seed.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Pattern guards. These are deliberately conservative; the goal is to
# refuse anything we cannot safely pass to a CLI.
$script:EasmDomainPattern = '^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9\-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'
$script:EasmIpv4Pattern   = '^(?:(?:25[0-5]|2[0-4]\d|[01]?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d?\d)$'
$script:EasmIpv6Pattern   = '^[0-9A-Fa-f:]{2,39}$'
$script:EasmCidrPattern   = '^(?:(?:25[0-5]|2[0-4]\d|[01]?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d?\d)/(?:3[0-2]|[12]?\d)$'
$script:EasmAsnPattern    = '^(?:AS)?\d{1,10}$'

function Test-EasmDomain { param ([string] $Value) return $Value -match $script:EasmDomainPattern }
function Test-EasmIp     { param ([string] $Value) return ($Value -match $script:EasmIpv4Pattern) -or ($Value -match $script:EasmIpv6Pattern) }
function Test-EasmCidr   { param ([string] $Value) return $Value -match $script:EasmCidrPattern }
function Test-EasmAsn    { param ([string] $Value) return $Value -match $script:EasmAsnPattern }

function ConvertTo-EasmStringSet {
    param (
        [object] $Items,
        [scriptblock] $Validator,
        [string] $Kind
    )

    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($raw in @($Items)) {
        if ($null -eq $raw) { continue }
        $value = ([string]$raw).Trim()
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        if ($value.Length -gt 253) {
            Write-Warning ("EasmSeed: discarding {0} entry (>253 chars)" -f $Kind)
            continue
        }
        if (-not (& $Validator $value)) {
            Write-Warning ("EasmSeed: discarding malformed {0} entry" -f $Kind)
            continue
        }
        $null = $set.Add($value.ToLowerInvariant())
    }
    return @($set | Sort-Object)
}

function Get-EasmSeedHash {
    param (
        [string[]] $Domains,
        [string[]] $Ips,
        [string[]] $Cidrs,
        [string[]] $Asns
    )

    $payload = ($Domains -join ',') + '|' + ($Ips -join ',') + '|' + ($Cidrs -join ',') + '|' + ($Asns -join ',')
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-EasmSeed {
    <#
    .SYNOPSIS
        Build a deterministic seed bundle for EASM wrappers.
    .PARAMETER Seed
        In-memory seed hashtable. Keys: Domains, Ips, Cidrs, Asns.
    .PARAMETER SeedFile
        Path to a JSON file with the same shape as -Seed.
    .PARAMETER ArgPublicIps
        Optional pre-fetched ARG result (array of IP strings) to merge.
        Wrappers and the orchestrator pass this through; the helper
        itself does not call Azure.
    .PARAMETER VerifiedDomains
        Optional pre-fetched Entra result (array of domain strings).
    .OUTPUTS
        PSCustomObject with Domains, Ips, Cidrs, Asns, Hash, SourceCount.
    .EXAMPLE
        $seed = Get-EasmSeed -SeedFile ./easm-seed.json
        Invoke-DnsTwist -Seed $seed
    #>
    [CmdletBinding()]
    param (
        [hashtable] $Seed,
        [string]    $SeedFile,
        [string[]]  $ArgPublicIps    = @(),
        [string[]]  $VerifiedDomains = @()
    )

    $domains = [System.Collections.Generic.List[string]]::new()
    $ips     = [System.Collections.Generic.List[string]]::new()
    $cidrs   = [System.Collections.Generic.List[string]]::new()
    $asns    = [System.Collections.Generic.List[string]]::new()

    $sources = 0
    if ($Seed) {
        $sources++
        if ($Seed.Contains('Domains')) { foreach ($d in @($Seed['Domains'])) { $domains.Add([string]$d) } }
        if ($Seed.Contains('Ips'))     { foreach ($i in @($Seed['Ips']))     { $ips.Add([string]$i) } }
        if ($Seed.Contains('Cidrs'))   { foreach ($c in @($Seed['Cidrs']))   { $cidrs.Add([string]$c) } }
        if ($Seed.Contains('Asns'))    { foreach ($a in @($Seed['Asns']))    { $asns.Add([string]$a) } }
    }

    if ($SeedFile) {
        if (-not (Test-Path -LiteralPath $SeedFile)) {
            Write-Warning "EasmSeed: SeedFile not found: $SeedFile"
        } else {
            try {
                $payload = Get-Content -LiteralPath $SeedFile -Raw | ConvertFrom-Json
                $sources++
                if ($payload.PSObject.Properties['domains']) { foreach ($d in @($payload.domains)) { $domains.Add([string]$d) } }
                if ($payload.PSObject.Properties['ips'])     { foreach ($i in @($payload.ips))     { $ips.Add([string]$i) } }
                if ($payload.PSObject.Properties['cidrs'])   { foreach ($c in @($payload.cidrs))   { $cidrs.Add([string]$c) } }
                if ($payload.PSObject.Properties['asns'])    { foreach ($a in @($payload.asns))    { $asns.Add([string]$a) } }
            } catch {
                Write-Warning "EasmSeed: failed to parse SeedFile ($SeedFile): $_"
            }
        }
    }

    if ($ArgPublicIps    -and $ArgPublicIps.Count    -gt 0) { foreach ($i in $ArgPublicIps)    { $ips.Add([string]$i) } ; $sources++ }
    if ($VerifiedDomains -and $VerifiedDomains.Count -gt 0) { foreach ($d in $VerifiedDomains) { $domains.Add([string]$d) } ; $sources++ }

    $cleanDomains = ConvertTo-EasmStringSet -Items $domains -Validator { param ($v) Test-EasmDomain $v } -Kind 'domain'
    $cleanIps     = ConvertTo-EasmStringSet -Items $ips     -Validator { param ($v) Test-EasmIp     $v } -Kind 'ip'
    $cleanCidrs   = ConvertTo-EasmStringSet -Items $cidrs   -Validator { param ($v) Test-EasmCidr   $v } -Kind 'cidr'
    $cleanAsns    = ConvertTo-EasmStringSet -Items $asns    -Validator { param ($v) Test-EasmAsn    $v } -Kind 'asn'

    $hash = Get-EasmSeedHash -Domains $cleanDomains -Ips $cleanIps -Cidrs $cleanCidrs -Asns $cleanAsns

    return [PSCustomObject]@{
        Domains     = $cleanDomains
        Ips         = $cleanIps
        Cidrs       = $cleanCidrs
        Asns        = $cleanAsns
        Hash        = $hash
        SourceCount = $sources
    }
}
