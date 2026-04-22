# Helper for issue #432a — render docs/tool-output-audit.md and
# docs/tool-output-audit.json from audit-raw.json.
[CmdletBinding()]
param([string] $RepoRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
$raw = Get-Content (Join-Path $RepoRoot 'audit-raw.json') -Raw | ConvertFrom-Json

# Curated FindingRow schema (modules/shared/Schema.ps1 v2.2 — for filter only).
$schemaSet = @(
    'Id','Source','EntityId','EntityType','Title','RuleId','Compliant','ProvenanceRunId',
    'Category','Severity','Detail','Remediation','ResourceId','LearnMoreUrl','Platform',
    'SubscriptionId','SubscriptionName','ResourceGroup','ManagementGroupPath','Frameworks',
    'Controls','Confidence','EvidenceCount','MissingDimensions','ProvenanceSource',
    'ProvenanceRawRecordRef','ProvenanceTimestamp','Pillar','Impact','Effort','DeepLinkUrl',
    'RemediationSnippets','EvidenceUris','BaselineTags','ScoreDelta','MitreTactics',
    'MitreTechniques','EntityRefs','ToolVersion','SchemaVersion'
)

# Envelope-level keys that are not per-finding semantic fields and therefore
# are NOT candidates for FindingRow extension.
$envelopeIgnore = @(
    'Errors','Findings','GeneratedAt','RunId','TenantId','Provider','Scope','Tool',
    'Status','SchemaVersion','Message','ExitCode','ContinuationToken','Body','Output',
    'name','rg','path','params','Path','Average','Total','Count','Sum','Min','Max',
    'Stderr','Stdout','Records','Items'
)

function Format-FieldList {
    param([string[]] $Items, [int] $Max = 8)
    if (-not $Items -or $Items.Count -eq 0) { return '_(none detected)_' }
    $shown = $Items | Select-Object -First $Max
    $more = $Items.Count - $shown.Count
    $s = ($shown | ForEach-Object { "``$_``" }) -join ', '
    if ($more -gt 0) { $s += " (+$more more)" }
    return $s
}

# --- Build markdown ---
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('# Tool output fidelity audit (#432a)')
[void]$sb.AppendLine()
[void]$sb.AppendLine('> Track D / sub-task **#432a** of epic #427. Audit-first, doc-only, no schema changes. Input for **#432b** (FindingRow extension) and **#432c** (per-family adoption), both deferred post-window per Round 3 reconciliation.')
[void]$sb.AppendLine()
[void]$sb.AppendLine('## Methodology — audit-first, delta-only')
[void]$sb.AppendLine()
[void]$sb.AppendLine('This audit is **static** and **delta-only**. For every tool registered in `tools/tool-manifest.json` (the single source of truth) we:')
[void]$sb.AppendLine()
[void]$sb.AppendLine('1. Locate the wrapper (`modules/Invoke-<Tool>.ps1`) and normalizer (`modules/normalizers/Normalize-<Tool>.ps1`).')
[void]$sb.AppendLine('2. Statically extract the property names emitted on raw / v1-envelope finding objects in the wrapper.')
[void]$sb.AppendLine('3. Statically extract the `New-FindingRow` parameters bound (directly or via splat hashtable) in the normalizer.')
[void]$sb.AppendLine('4. Cross-reference the v2.2 `FindingRow` schema in `modules/shared/Schema.ps1`.')
[void]$sb.AppendLine('5. Diff (1) → (3) and classify each wrapper-emitted field as `preserved`, `suspected-dropped`, `confirmed-dropped`, or `n/a` (envelope/diagnostic).')
[void]$sb.AppendLine()
[void]$sb.AppendLine('Static analysis catches the majority of dropped fields, but per-tenant runtime payloads can include additional optional properties not visible to the script. Where confirmation requires actual tool execution against a live tenant we mark **`pending-real-tenant-run`** instead of **`complete`**. This is honest scope-flagging — #432b will only schema-add fields in the **`confirmed-dropped`** column built from the union of static analysis + the runtime-fixture pass that ships under #432c.')
[void]$sb.AppendLine()
[void]$sb.AppendLine('Sidecar machine-readable data: [`tool-output-audit.json`](./tool-output-audit.json).')
[void]$sb.AppendLine()
[void]$sb.AppendLine('## Tool inventory')
[void]$sb.AppendLine()
[void]$sb.AppendLine(('Total tools registered: **{0}**  (enabled: **{1}**, disabled: **{2}**).' -f $raw.Count, ($raw | Where-Object Enabled).Count, ($raw | Where-Object { -not $_.Enabled }).Count))
[void]$sb.AppendLine()
[void]$sb.AppendLine('| Tool | Provider | Scope | Wrapper file | Wrapper-preserved fields | Normalizer-preserved fields | Tool-emitted fields not preserved (suspected) | Audit status |')
[void]$sb.AppendLine('| --- | --- | --- | --- | --- | --- | --- | --- |')

$sidecar = New-Object System.Collections.Generic.List[object]

foreach ($e in $raw) {
    $wrapperFile = if ($e.WrapperFile) { "``$($e.WrapperFile)``" } else { '_(none)_' }
    # Suspected-dropped = wrapper field that is neither in schema nor an
    # envelope/diagnostic key, and not present in normalizer output set.
    $candidates = $e.WrapperFields | Where-Object {
        $_ -and ($_ -notin $envelopeIgnore) -and ($_ -notin $schemaSet) -and ($_ -notin $e.NormalizerSchemaFields)
    } | Sort-Object -Unique
    $status = if (-not $e.Enabled) {
        'disabled (skipped)'
    } elseif (-not $e.WrapperFile -or -not $e.NormalizerFile) {
        'pending-real-tenant-run (post-processor; not a finding-emitting wrapper)'
    } elseif ($e.WrapperFields.Count -eq 0) {
        'pending-real-tenant-run (wrapper uses dynamic finding shape; static extract empty)'
    } else {
        'complete (static); pending-real-tenant-run for runtime confirmation'
    }
    $row = '| `{0}` | {1} | {2} | {3} | {4} | {5} | {6} | {7} |' -f `
        $e.Tool, $e.Provider, $e.Scope, $wrapperFile, `
        (Format-FieldList -Items $e.WrapperFields -Max 6), `
        (Format-FieldList -Items $e.NormalizerSchemaFields -Max 6), `
        (Format-FieldList -Items $candidates -Max 6), `
        $status
    [void]$sb.AppendLine($row)

    $sidecar.Add([pscustomobject]@{
        tool                                = $e.Tool
        displayName                         = $e.DisplayName
        provider                            = $e.Provider
        scope                               = $e.Scope
        enabled                             = $e.Enabled
        wrapperFile                         = $e.WrapperFile
        normalizerFile                      = $e.NormalizerFile
        wrapperFieldsPreserved              = @($e.WrapperFields)
        normalizerFieldsPreserved           = @($e.NormalizerSchemaFields)
        suspectedDroppedToolEmittedFields   = @($candidates)
        schemaFieldsNotEmittedByNormalizer  = @($e.SchemaFieldsMissing)
        auditStatus                         = $status
    })
}

# --- Aggregate candidate fields for #432b ---
$globalTally = @{}
foreach ($s in $sidecar) {
    if (-not $s.enabled) { continue }
    foreach ($f in $s.suspectedDroppedToolEmittedFields) {
        if (-not $globalTally.ContainsKey($f)) { $globalTally[$f] = 0 }
        $globalTally[$f]++
    }
}

[void]$sb.AppendLine()
[void]$sb.AppendLine('## Candidate FindingRow additions for #432b')
[void]$sb.AppendLine()
[void]$sb.AppendLine('Fields below are emitted by one or more tool wrappers but have **no home in the current `FindingRow`** and are not preserved by their normalizer. Ordered by occurrence count across the enabled tool set. **#432b** will use this list to propose additive schema fields after foundation #435 lands; **#432c** will then drive per-family normalizer adoption.')
[void]$sb.AppendLine()
[void]$sb.AppendLine('| # | Candidate field | Occurrence (tools) | Notes |')
[void]$sb.AppendLine('| --- | --- | ---:| --- |')

$noteFor = @{
    'AdoOrg'                = 'ADO organisation context — currently leaks into Detail blob.'
    'AdoProject'            = 'ADO project context — currently leaks into Detail blob.'
    'CommitSha'             = 'Git commit SHA for SCM-scoped findings (gitleaks, scorecard, zizmor, trivy).'
    'CommitUrl'             = 'Browser-deep-link to the offending commit; useful for HTML report drilldowns.'
    'Repo'                  = 'Short owner/repo identifier (distinct from `EntityId` canonical form).'
    'RepositoryId'          = 'GitHub numeric repo id; useful for cross-correlation.'
    'RepositoryCanonicalId' = 'Canonical repo entity id when wrapper produces multiple kinds.'
    'Currency'              = 'ISO 4217 currency for cost-bearing findings (azure-cost, infracost, finops).'
    'SecretType'            = 'Detector classification for secret-scanner findings (gitleaks, ado-repos-secrets).'
    'ResourceType'          = 'ARM resource type already present in `ResourceId`, but explicit field eases grouping.'
    'ResourceName'          = 'Display name distinct from canonical id; HTML report uses it today via Detail parsing.'
    'Location'              = 'Azure region for the finding subject; useful for residency / quota dashboards.'
    'RecommendationId'      = 'Stable advisor / WARA / reliability recommendation id; overlaps with `RuleId` but emitted distinctly.'
    'Recommendation'        = 'Free-form recommendation string from advisor-style tools.'
    'LineNumber'            = 'Source line for SCA / SAST / IaC findings — drives editor deep-links.'
    'Path'                  = 'Source file path (relative to repo root) for SCA / SAST / IaC findings.'
    'QueryIntent'           = 'Copilot-triage classified user intent label (when triage is enabled).'
    'DisablesDefaultsWithoutCustomRules' = 'PSRule meta-flag indicating baseline-suppressed rule set.'
}

$rank = 0
foreach ($kv in ($globalTally.GetEnumerator() | Sort-Object @{Expression='Value';Descending=$true}, @{Expression='Key';Descending=$false})) {
    $rank++
    $note = if ($noteFor.ContainsKey($kv.Key)) { $noteFor[$kv.Key] } else { '' }
    [void]$sb.AppendLine(('| {0} | `{1}` | {2} | {3} |' -f $rank, $kv.Key, $kv.Value, $note))
}

[void]$sb.AppendLine()
[void]$sb.AppendLine('## Existing FindingRow optional fields with low normalizer adoption')
[void]$sb.AppendLine()
[void]$sb.AppendLine('Schema v2.2 already defines these fields, but most normalizers do not yet populate them. They are **not** new schema work — they are **adoption gaps** for #432c. Listed by miss-count across the 36 enabled tools.')
[void]$sb.AppendLine()
[void]$sb.AppendLine('| Schema field | Normalizers not populating |')
[void]$sb.AppendLine('| --- | ---:|')
$missTally = @{}
foreach ($s in $sidecar) {
    if (-not $s.enabled -or -not $s.normalizerFile) { continue }
    foreach ($f in $s.schemaFieldsNotEmittedByNormalizer) {
        if (-not $missTally.ContainsKey($f)) { $missTally[$f] = 0 }
        $missTally[$f]++
    }
}
$additiveFocus = @('Pillar','Impact','Effort','DeepLinkUrl','RemediationSnippets','EvidenceUris','BaselineTags','ScoreDelta','MitreTactics','MitreTechniques','EntityRefs','ToolVersion','RuleId','Frameworks','Controls')
foreach ($kv in ($missTally.GetEnumerator() | Where-Object { $_.Key -in $additiveFocus } | Sort-Object @{Expression='Value';Descending=$true}, @{Expression='Key';Descending=$false})) {
    [void]$sb.AppendLine(('| `{0}` | {1} |' -f $kv.Key, $kv.Value))
}

[void]$sb.AppendLine()
[void]$sb.AppendLine('## Audit status legend')
[void]$sb.AppendLine()
[void]$sb.AppendLine('- **complete (static)** — wrapper + normalizer both inspected; field deltas computed from source.')
[void]$sb.AppendLine('- **pending-real-tenant-run** — confirmation requires running the tool against a live Azure / M365 / GitHub / ADO tenant. Most rows carry this flag because per-tenant payloads frequently expose optional properties not visible to static analysis.')
[void]$sb.AppendLine('- **disabled (skipped)** — tool is `enabled: false` in the manifest (e.g. `copilot-triage`).')
[void]$sb.AppendLine()
[void]$sb.AppendLine('## How to regenerate this audit')
[void]$sb.AppendLine()
[void]$sb.AppendLine('```powershell')
[void]$sb.AppendLine('# 1. Static field extraction → audit-raw.json')
[void]$sb.AppendLine('pwsh -NoProfile -File scripts/audit-tool-fields.ps1')
[void]$sb.AppendLine('# 2. Render markdown + sidecar JSON')
[void]$sb.AppendLine('pwsh -NoProfile -File scripts/render-tool-output-audit.ps1')
[void]$sb.AppendLine('```')
[void]$sb.AppendLine()
[void]$sb.AppendLine('Both scripts read `tools/tool-manifest.json` (the single source of truth — see `.github/copilot-instructions.md`). Adding or removing a tool there will propagate into the next audit regeneration without further edits.')

$mdPath = Join-Path $RepoRoot 'docs\tool-output-audit.md'
$jsonPath = Join-Path $RepoRoot 'docs\tool-output-audit.json'
Set-Content -Path $mdPath -Value $sb.ToString() -Encoding UTF8

$payload = [pscustomobject]@{
    schemaVersion        = '2.0'
    generatedForIssue    = '#432a'
    epic                 = '#427'
    methodology          = 'static-first, delta-only; pending-real-tenant-run flagged honestly'
    schemaReference      = 'modules/shared/Schema.ps1 (FindingRow v2.2)'
    manifestSource       = 'tools/tool-manifest.json'
    totalTools           = $sidecar.Count
    enabledTools         = ($sidecar | Where-Object enabled).Count
    candidateFindingRowAdditions = (
        $globalTally.GetEnumerator() | Sort-Object @{Expression='Value';Descending=$true}, @{Expression='Key';Descending=$false} | ForEach-Object {
            [pscustomobject]@{ field = $_.Key; occurrenceCount = $_.Value }
        }
    )
    schemaFieldsAdoptionGap = (
        $missTally.GetEnumerator() | Where-Object { $_.Key -in $additiveFocus } | Sort-Object @{Expression='Value';Descending=$true}, @{Expression='Key';Descending=$false} | ForEach-Object {
            [pscustomobject]@{ field = $_.Key; normalizersNotPopulating = $_.Value }
        }
    )
    entries              = $sidecar
}
$payload | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8
Write-Host "Wrote $mdPath"
Write-Host "Wrote $jsonPath"
