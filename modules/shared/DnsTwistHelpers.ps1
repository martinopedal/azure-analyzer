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

    $hasA    = $Record.PSObject.Properties['dns_a']    -and @($Record.dns_a).Count    -gt 0
    $hasMx   = $Record.PSObject.Properties['dns_mx']   -and @($Record.dns_mx).Count   -gt 0
    $hasNs   = $Record.PSObject.Properties['dns_ns']   -and @($Record.dns_ns).Count   -gt 0
    $hasAaaa = $Record.PSObject.Properties['dns_aaaa'] -and @($Record.dns_aaaa).Count -gt 0

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
