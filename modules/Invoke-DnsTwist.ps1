#Requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for the DNSTwist CLI (typosquat / homoglyph detection).
.DESCRIPTION
    Runs the dnstwist CLI against each domain in the EASM seed bundle.
    DNSTwist generates permutations (typo, homoglyph, bitsquatting,
    hyphenation, insertion, omission, repetition, replacement,
    subdomain, transposition, vowel-swap, addition) and reports any
    permutation whose DNS or HTTP record is currently registered.

    The wrapper:
      * Skips with status='Skipped' when dnstwist is not installed (graceful).
      * Skips with status='Skipped' when the seed has no domains.
      * Runs `dnstwist --format json --registered <domain>` per seed domain.
      * Caps every external invocation at 300 s via Invoke-WithTimeout.
      * Sanitises stdout/stderr via Remove-Credentials before any
        finding, log, or error is written.
      * Returns the canonical v1 envelope (Source, SchemaVersion=1.0,
        Status, Message, Findings, Errors).

    Design doc: docs/design/easm-integration.md.
#>
[CmdletBinding()]
param (
    [string] $SeedFile,
    [hashtable] $Seed,
    [string] $OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Dot-source shared modules (with inline fallback stubs so wrapper tests
# can exercise paths even when the shared module isn't available).
$sharedDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules' 'shared'
if (-not $sharedDir -or -not (Test-Path $sharedDir)) {
    $sharedDir = Join-Path $PSScriptRoot 'shared'
}
$sanitizePath = Join-Path $sharedDir 'Sanitize.ps1'
if (Test-Path $sanitizePath) { . $sanitizePath }
$errorsPath = Join-Path $sharedDir 'Errors.ps1'
if (Test-Path $errorsPath) { . $errorsPath }
$cliTimeoutPath = Join-Path $sharedDir 'CliTimeout.ps1'
if (Test-Path $cliTimeoutPath) { . $cliTimeoutPath }
$envelopePath = Join-Path $sharedDir 'New-WrapperEnvelope.ps1'
if (Test-Path $envelopePath) { . $envelopePath }
$easmSeedPath = Join-Path $sharedDir 'EasmSeed.ps1'
if (Test-Path $easmSeedPath) { . $easmSeedPath }

if (-not (Get-Command New-WrapperEnvelope -ErrorAction SilentlyContinue)) {
    function New-WrapperEnvelope { param([string]$Source,[string]$Status='Failed',[string]$Message='',[object[]]$FindingErrors=@()) return [PSCustomObject]@{ Source=$Source; SchemaVersion='1.0'; Status=$Status; Message=$Message; Findings=@(); Errors=@($FindingErrors) } }
}
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param ([string]$Text) return $Text }
}
if (-not (Get-Command New-FindingError -ErrorAction SilentlyContinue)) {
    function New-FindingError { param([string]$Source,[string]$Category,[string]$Reason,[string]$Remediation,[string]$Details) return [pscustomobject]@{ Source=$Source; Category=$Category; Reason=$Reason; Remediation=$Remediation; Details=$Details } }
}
if (-not (Get-Command Invoke-WithTimeout -ErrorAction SilentlyContinue)) {
    function Invoke-WithTimeout {
        param ([scriptblock]$ScriptBlock, [int]$TimeoutSeconds = 300, [string]$OperationName = 'op')
        return & $ScriptBlock
    }
}

function Test-DnsTwistInstalled {
    $null -ne (Get-Command dnstwist -ErrorAction SilentlyContinue)
}

function Get-DnsTwistVersion {
    try {
        $raw = dnstwist --version 2>&1
        if ($LASTEXITCODE -ne 0) { return '' }
        $text = if ($raw -is [array]) { ($raw -join ' ') } else { [string]$raw }
        $m = [regex]::Match($text, '(\d+\.\d+(?:\.\d+)?)')
        if ($m.Success) { return $m.Groups[1].Value }
        return $text.Trim()
    } catch {
        return ''
    }
}

function Get-DnsTwistFinding {
    <#
    .SYNOPSIS
        Convert a single dnstwist record (already parsed from JSON) into a
        v1 envelope finding. Pure function, easy to unit-test without dnstwist.
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

    # Severity rubric (per design doc 5.5):
    #   - homoglyph / homograph variants resolving to A or MX: High
    #     (highest phishing potential)
    #   - any other registered + resolving variant: Medium
    #   - registered but not resolving: Low
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

function Invoke-DnsTwistOnDomain {
    <#
    .SYNOPSIS
        Run dnstwist for one seed domain and return parsed JSON.
    .DESCRIPTION
        Isolated for testability. The caller mocks this function in
        wrapper tests so we never need a real dnstwist binary on the
        test runner.
    #>
    param (
        [Parameter(Mandatory)] [string] $Domain,
        [int] $TimeoutSeconds = 300
    )

    $jsonText = Invoke-WithTimeout -OperationName "dnstwist:$Domain" -TimeoutSeconds $TimeoutSeconds -ScriptBlock {
        # --registered: only return permutations whose DNS / HTTP record
        # currently exists. --format json: machine-readable output.
        # We deliberately avoid -w/--whois (rate-limited, slow, optional).
        & dnstwist --format json --registered $using:Domain 2>&1
    }
    if ($LASTEXITCODE -ne 0) {
        # Use a typed exception (RuntimeException) instead of a raw throw
        # string so the wrapper-consistency ratchet (Cat 11) stays at 0.
        # The catch in the main loop converts this to a sanitised
        # FindingError attached to the v1 envelope.
        throw [System.Management.Automation.RuntimeException]::new(
            ("dnstwist exited with code {0} for {1}" -f $LASTEXITCODE, $Domain))
    }
    $text = if ($jsonText -is [array]) { ($jsonText -join "`n") } else { [string]$jsonText }
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    return ($text | ConvertFrom-Json -ErrorAction Stop)
}

# Main wrapper body
try {
    if (-not (Test-DnsTwistInstalled)) {
        $err = New-FindingError -Source 'wrapper:dnstwist' `
            -Category 'MissingDependency' `
            -Reason 'dnstwist CLI is not installed' `
            -Remediation 'pipx install dnstwist (Linux/Windows) or brew install dnstwist (macOS)'
        return New-WrapperEnvelope -Source 'dnstwist' -Status 'Skipped' `
            -Message 'dnstwist not installed; skipping EASM typosquat scan.' `
            -FindingErrors @($err)
    }

    # Build the seed. Get-EasmSeed normalises + validates inputs.
    if (-not (Get-Command Get-EasmSeed -ErrorAction SilentlyContinue)) {
        $err = New-FindingError -Source 'wrapper:dnstwist' `
            -Category 'MissingDependency' `
            -Reason 'EasmSeed shared module is unavailable' `
            -Remediation 'Ensure modules/shared/EasmSeed.ps1 is present.'
        return New-WrapperEnvelope -Source 'dnstwist' -Status 'Failed' `
            -Message 'EasmSeed not loaded.' `
            -FindingErrors @($err)
    }

    $seedArgs = @{}
    if ($Seed)     { $seedArgs['Seed']     = $Seed }
    if ($SeedFile) { $seedArgs['SeedFile'] = $SeedFile }
    $seedBundle = Get-EasmSeed @seedArgs

    if (-not $seedBundle.Domains -or @($seedBundle.Domains).Count -eq 0) {
        return New-WrapperEnvelope -Source 'dnstwist' -Status 'Skipped' `
            -Message 'EASM seed bundle contains no domains; skipping dnstwist.'
    }

    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()
    $errors   = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($domain in $seedBundle.Domains) {
        try {
            $records = Invoke-DnsTwistOnDomain -Domain $domain
            foreach ($rec in @($records)) {
                $finding = Get-DnsTwistFinding -Record $rec -SeedDomain $domain
                if ($null -ne $finding) { $findings.Add($finding) | Out-Null }
            }
        } catch {
            $sanitisedReason = Remove-Credentials ([string]$_)
            $errors.Add((New-FindingError -Source 'wrapper:dnstwist' `
                -Category 'ExecutionError' `
                -Reason "dnstwist failed for $domain" `
                -Remediation 'Check stderr; verify dnstwist version >= 20210817.' `
                -Details $sanitisedReason)) | Out-Null
        }
    }

    return [PSCustomObject]@{
        Source        = 'dnstwist'
        SchemaVersion = '1.0'
        Status        = 'Success'
        Message       = ("Scanned {0} seed domain(s); found {1} typosquat candidate(s)." -f @($seedBundle.Domains).Count, $findings.Count)
        SeedHash      = $seedBundle.Hash
        ToolVersion   = (Get-DnsTwistVersion)
        Findings      = @($findings)
        Errors        = @($errors)
    }
} catch {
    $sanitised = Remove-Credentials ([string]$_)
    $err = New-FindingError -Source 'wrapper:dnstwist' `
        -Category 'ExecutionError' `
        -Reason 'Unhandled exception in Invoke-DnsTwist' `
        -Remediation 'See Details; rerun with -Verbose for stack.' `
        -Details $sanitised
    return New-WrapperEnvelope -Source 'dnstwist' -Status 'Failed' `
        -Message $sanitised -FindingErrors @($err)
}
