#Requires -Version 7.4
<#
.SYNOPSIS
    Cross-run suppression (false-positive / accepted-risk) support.
.DESCRIPTION
    Large scans surface findings a team has already reviewed and accepted.
    Without a first-class suppression mechanism every re-run reproduces the
    full list and the counts never reflect the team's triage decisions.

    Identity is the hard part. The FindingRow 'Id' field cannot be used as a
    suppression key: 37 of the 38 normalizers fall back to
    [guid]::NewGuid() when the underlying tool supplies no id of its own, so
    Id is deliberately unique per run. A suppression list keyed on it would
    silently stop matching after the very first re-scan, which is worse than
    having no suppression at all because the failure is invisible.

    Get-FindingKey therefore derives a key from fields that are stable by
    construction:

      Source   - the tool name, a required FindingRow field.
      RuleId   - the tool's own rule identifier when present. Only 27 of 38
                 normalizers populate it (WARA, the highest-volume tool, does
                 not), so Title is used as the fallback. Title is required and
                 non-empty on every FindingRow.
      EntityId - required, and already canonicalised (lowercased ARM ids,
                 tenant:{guid} and so on) by ConvertTo-CanonicalEntityId, so
                 casing and formatting drift cannot change the key.

    Findings are marked, never dropped: raw data keeps every finding so an
    audit trail survives, and only the actionable counts and default report
    views exclude suppressed rows.
#>
[CmdletBinding()]
param ()

$script:SuppressionSchemaVersion = '1.0'

function Get-FindingKey {
    <#
    .SYNOPSIS
        Computes a stable, run-independent identity for a finding.
    .DESCRIPTION
        SHA-256 over 'source|rule|entity', truncated to 16 hex characters.

        Truncation is safe here because the key is a lookup handle for a
        human-curated list, not a security boundary: 64 bits over a few
        thousand findings leaves collision probability negligible, and a
        collision would at worst suppress one extra finding in the same
        tenant rather than grant access to anything.

        Components are lowercased and trimmed so that incidental casing
        differences between tool versions do not invalidate a curated list.
    .PARAMETER Finding
        A v3 FindingRow (or any object exposing Source, RuleId/Title, EntityId).
    .OUTPUTS
        [string] 16-character lowercase hex, or '' when identity is incomplete.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object] $Finding
    )
    process {
        if ($null -eq $Finding) { return '' }

        $source = Get-SuppressionField -Object $Finding -Name 'Source'
        $entity = Get-SuppressionField -Object $Finding -Name 'EntityId'
        $rule = Get-SuppressionField -Object $Finding -Name 'RuleId'
        if ([string]::IsNullOrWhiteSpace($rule)) {
            $rule = Get-SuppressionField -Object $Finding -Name 'Title'
        }

        # Source and EntityId are both required FindingRow fields. If either is
        # missing the object is not a well-formed finding, and returning a key
        # anyway would let unrelated malformed rows collide on the same handle.
        if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($entity)) { return '' }
        if ([string]::IsNullOrWhiteSpace($rule)) { return '' }

        return Get-SuppressionHash -Source $source -Rule $rule -Entity $entity
    }
}

function Get-SuppressionHash {
    <#
    .SYNOPSIS
        Shared hashing used by both Get-FindingKey and explicit list entries.
    .DESCRIPTION
        Kept separate so a hand-authored suppression entry that specifies
        source/rule/entity produces byte-identical output to the key computed
        from a live finding. If these two ever diverged, hand-authored entries
        would silently never match.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $Rule,
        [Parameter(Mandatory)] [string] $Entity
    )
    $material = '{0}|{1}|{2}' -f $Source.Trim().ToLowerInvariant(), $Rule.Trim().ToLowerInvariant(), $Entity.Trim().ToLowerInvariant()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($material))
    } finally {
        $sha.Dispose()
    }
    return -join ($bytes[0..7] | ForEach-Object { $_.ToString('x2') })
}

function Get-SuppressionField {
    <#
    .SYNOPSIS
        StrictMode-safe property read.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Object,
        [Parameter(Mandatory)] [string] $Name
    )
    if ($Object -is [hashtable]) {
        if ($Object.ContainsKey($Name) -and $null -ne $Object[$Name]) { return [string]$Object[$Name] }
        return ''
    }
    if ($Object.PSObject.Properties[$Name]) {
        $value = $Object.$Name
        if ($null -ne $value) { return [string]$value }
    }
    return ''
}

function Import-SuppressionList {
    <#
    .SYNOPSIS
        Loads and validates a suppression list from disk.
    .DESCRIPTION
        Accepts JSON in the shape:

            {
              "schemaVersion": "1.0",
              "suppressions": [
                { "key": "a1b2c3d4e5f60718", "reason": "Risk accepted", "expires": "2026-12-31" },
                { "source": "wara", "ruleId": "...", "entityId": "/subscriptions/...", "reason": "..." }
              ]
            }

        Two entry forms are supported on purpose. The 'key' form is what a
        machine-generated list looks like (an interactive report exporting a
        triage decision), while the source/ruleId/entityId triple is
        reviewable in a pull request by someone who cannot run the hash. Both
        resolve through Get-SuppressionHash, so they cannot drift apart.

        'reason' is mandatory. A suppression list without reasons becomes
        unauditable within one staff rotation, and the whole point of the
        feature is to make accepted risk explicit rather than invisible.

        'expires' is optional and, when present, must be a parseable date.
        An expired entry is reported and ignored rather than silently applied,
        so accepted risk has to be re-confirmed instead of persisting forever.

        A malformed file is a hard error: silently scanning without the
        suppressions the operator asked for would misreport the risk posture.
        Individual malformed entries are collected and reported together so a
        long list can be fixed in one pass.
    .OUTPUTS
        [pscustomobject] with Entries (hashtable keyed by hash) and Errors.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [datetime] $Now = [datetime]::UtcNow
    )

    $result = [pscustomobject]@{
        Entries = @{}
        Errors  = @()
        Expired = @()
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        $result.Errors = @("Suppression file not found: $Path")
        return $result
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    } catch {
        $result.Errors = @("Suppression file could not be read: $([string]$_)")
        return $result
    }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        $result.Errors = @("Suppression file is empty: $Path")
        return $result
    }

    try {
        $doc = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $result.Errors = @("Suppression file is not valid JSON: $([string]$_)")
        return $result
    }

    $entries = @()
    if ($doc.PSObject.Properties['suppressions'] -and $doc.suppressions) {
        $entries = @($doc.suppressions)
    } elseif ($doc -is [array]) {
        # Tolerate a bare array; it is the obvious thing to hand-write.
        $entries = @($doc)
    } elseif ($doc.PSObject.Properties['key'] -or $doc.PSObject.Properties['source']) {
        # ConvertFrom-Json collapses a single-element array to a bare object,
        # so a one-entry hand-written list arrives here rather than above.
        $entries = @($doc)
    } else {
        $result.Errors = @("Suppression file has no 'suppressions' array.")
        return $result
    }

    $errors = [System.Collections.Generic.List[string]]::new()
    $expired = [System.Collections.Generic.List[string]]::new()
    $map = @{}
    $index = 0

    foreach ($entry in $entries) {
        $index++
        if ($null -eq $entry) { continue }

        $reason = Get-SuppressionField -Object $entry -Name 'reason'
        if ([string]::IsNullOrWhiteSpace($reason)) {
            $errors.Add("Entry $index is missing a 'reason'.")
            continue
        }

        $key = Get-SuppressionField -Object $entry -Name 'key'
        if ([string]::IsNullOrWhiteSpace($key)) {
            $source = Get-SuppressionField -Object $entry -Name 'source'
            $entity = Get-SuppressionField -Object $entry -Name 'entityId'
            $rule = Get-SuppressionField -Object $entry -Name 'ruleId'
            if ([string]::IsNullOrWhiteSpace($rule)) {
                $rule = Get-SuppressionField -Object $entry -Name 'title'
            }
            if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($entity) -or [string]::IsNullOrWhiteSpace($rule)) {
                $errors.Add("Entry $index needs either 'key', or all of 'source', 'entityId' and one of 'ruleId'/'title'.")
                continue
            }
            $key = Get-SuppressionHash -Source $source -Rule $rule -Entity $entity
        } else {
            $key = $key.Trim().ToLowerInvariant()
            if ($key -notmatch '^[0-9a-f]{16}$') {
                $errors.Add("Entry $index has key '$key', which is not a 16-character hex finding key.")
                continue
            }
        }

        $expiresRaw = Get-SuppressionField -Object $entry -Name 'expires'
        if (-not [string]::IsNullOrWhiteSpace($expiresRaw)) {
            [datetime] $expiresAt = [datetime]::MinValue
            if (-not [datetime]::TryParse($expiresRaw, [ref] $expiresAt)) {
                $errors.Add("Entry $index has an unparseable 'expires' value '$expiresRaw'.")
                continue
            }
            if ($expiresAt -lt $Now) {
                $expired.Add("$key (expired $($expiresAt.ToString('yyyy-MM-dd')): $reason)")
                continue
            }
        }

        $map[$key] = [pscustomobject]@{
            Key     = $key
            Reason  = $reason
            Expires = $expiresRaw
        }
    }

    $result.Entries = $map
    $result.Errors = @($errors)
    $result.Expired = @($expired)
    return $result
}

function Set-FindingSuppression {
    <#
    .SYNOPSIS
        Marks findings that match a suppression list.
    .DESCRIPTION
        Findings are annotated in place with Suppressed / SuppressionReason /
        FindingKey and are always retained. Callers exclude them from
        actionable counts and default views; the raw data keeps them so the
        decision stays auditable and a suppression can be reversed without
        re-running the scan.

        FindingKey is stamped on every finding, matched or not, because the
        interactive report needs a key to offer "suppress this" against, and
        computing it once here keeps it consistent with what the matcher used.
    .OUTPUTS
        [pscustomobject] summary with Total, Suppressed and UnusedKeys.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object[]] $Findings,

        [Parameter(Mandatory)]
        [hashtable] $Entries
    )

    $total = 0
    $suppressed = 0
    $used = @{}

    foreach ($finding in @($Findings)) {
        if ($null -eq $finding) { continue }
        $total++

        $key = Get-FindingKey -Finding $finding
        Set-SuppressionProperty -Finding $finding -Name 'FindingKey' -Value $key

        $isSuppressed = $false
        $reason = ''
        if ($key -and $Entries.ContainsKey($key)) {
            $isSuppressed = $true
            $reason = [string]$Entries[$key].Reason
            $used[$key] = $true
            $suppressed++
        }

        Set-SuppressionProperty -Finding $finding -Name 'Suppressed' -Value $isSuppressed
        Set-SuppressionProperty -Finding $finding -Name 'SuppressionReason' -Value $reason
    }

    # Unused keys are surfaced rather than ignored: they usually mean a
    # resource was deleted or a rule id changed, and a suppression list that
    # quietly stops matching is exactly the failure mode this design avoids.
    $unused = @($Entries.Keys | Where-Object { -not $used.ContainsKey($_) })

    return [pscustomobject]@{
        Total      = $total
        Suppressed = $suppressed
        UnusedKeys = $unused
    }
}

function Set-SuppressionProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Finding,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter()] [AllowNull()] [object] $Value
    )
    if ($Finding.PSObject.Properties[$Name]) {
        $Finding.$Name = $Value
    } else {
        $Finding | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
    }
}