#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Pure helpers for the dnstwist wrapper. Extracted from
    modules/Invoke-DnsTwist.ps1 so unit tests can exercise the real
    implementation (instead of re-declaring it inline and risking drift).
#>

function Get-DnsTwistFinding {
    <#
    .SYNOPSIS
        Convert a single dnstwist record (already parsed from JSON) into a
        v1 envelope finding. Pure function, easy to unit-test without dnstwist.
    .DESCRIPTION
        Severity rubric (per docs/design/easm-integration.md s5.5):
          - homoglyph / homograph + DNS-registered: High
            (any DNS record A/AAAA/MX/NS counts as registered; these
            permutations have the highest phishing potential and any
            live DNS makes them weaponisable)
          - any other registered + resolving variant: Medium
          - registered but not resolving: Low
    #>
    param (
        [Parameter(Mandatory)] [object] $Record,
        [Parameter(Mandatory)] [string] $SeedDomain
    )

    $fuzzer = if ($Record.PSObject.Properties['fuzzer']) { [string]$Record.fuzzer } else { '' }
    $domain = if ($Record.PSObject.Properties['domain']) { [string]$Record.domain } else { '' }
    if ([string]::IsNullOrWhiteSpace($domain)) { return $null }

    # Skip the synthetic "original*" record that dnstwist always emits as
    # the first entry. It's the seed domain itself, not a typosquat.
    if ($fuzzer -like 'original*') { return $null }

    # Robustly check for non-empty DNS record arrays. dnstwist sometimes
    # emits dns_a/dns_mx as JSON null; in PowerShell @($null).Count is 1,
    # so we must filter out null/empty entries before counting.
    function script:Test-DnsRecordPresent {
        param ($Record, [string] $Name)
        if (-not $Record.PSObject.Properties[$Name]) { return $false }
        $val = $Record.$Name
        if ($null -eq $val) { return $false }
        $items = @($val) | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) }
        return @($items).Count -gt 0
    }
    $hasA    = Test-DnsRecordPresent -Record $Record -Name 'dns_a'
    $hasMx   = Test-DnsRecordPresent -Record $Record -Name 'dns_mx'
    $hasNs   = Test-DnsRecordPresent -Record $Record -Name 'dns_ns'
    $hasAaaa = Test-DnsRecordPresent -Record $Record -Name 'dns_aaaa'

    $registered = $hasA -or $hasMx -or $hasNs -or $hasAaaa
    $severity = if (-not $registered) { 'Low' }
                elseif ($fuzzer -match 'homoglyph|homograph') { 'High' }
                else { 'Medium' }

    $detailParts = [System.Collections.Generic.List[string]]::new()
    $detailParts.Add(("Permutation '{0}' of seed '{1}' is registered." -f $fuzzer, $SeedDomain)) | Out-Null
    if ($hasA)    { $detailParts.Add("A: $((@($Record.dns_a) -join ', '))") | Out-Null }
    if ($hasMx)   { $detailParts.Add("MX: $((@($Record.dns_mx) -join ', '))") | Out-Null }
    if ($hasNs)   { $detailParts.Add("NS: $((@($Record.dns_ns) -join ', '))") | Out-Null }

    return [PSCustomObject]@{
        Id           = "dnstwist:${SeedDomain}:${fuzzer}:${domain}"
        RuleId       = "dnstwist-$fuzzer"
        Title        = "Possible typosquat: $domain (variant of $SeedDomain)"
        Category     = 'External Attack Surface'
        Severity     = $severity
        Compliant    = $false
        Detail       = ($detailParts -join ' ')
        Remediation  = 'Investigate ownership; consider defensive registration or takedown if malicious.'
        ResourceId   = $domain
        Pillar       = 'Exposure'
        Impact       = if ($severity -eq 'High') { 'High' } else { 'Medium' }
        Effort       = 'Medium'
        DeepLinkUrl  = "https://dnstwist.it/?domain=$SeedDomain"
        SeedDomain   = $SeedDomain
        Permutation  = $domain
        Fuzzer       = $fuzzer
    }
}
