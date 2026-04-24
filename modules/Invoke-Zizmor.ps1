#Requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for zizmor CLI (GitHub Actions YAML scanner).
.DESCRIPTION
    Runs the zizmor CLI against GitHub Actions workflow files to detect security
    issues such as expression injection, untrusted input, and unpinned actions.
    If zizmor is not installed, writes a warning and returns an empty result.
    Never throws -- designed for graceful degradation in the orchestrator.

    JSON output is written to a temp file (--output) to avoid stderr/stdout
    mixing. The temp file is cleaned up in a finally block.
.PARAMETER RepoPath
    Path to the repository root to scan. Required.
    Legacy alias: -Repository.
.PARAMETER WorkflowPath
    Relative path to the workflows directory. Defaults to .github/workflows.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param (
    [Alias('Repository')]
    [string] $RepoPath,

    [string] $WorkflowPath = '.github/workflows',

    [string] $RemoteUrl,

    # Incremental hint (#94). When non-null, the wrapper reports RunMode=Incremental
    # in its result envelope so the orchestrator state layer can record accurate
    # per-tool run modes. Zizmor itself scans static workflow YAML, so the
    # timestamp does not narrow the scan -- but the hint still flows through
    # so reports and state correctly reflect incremental coverage.
    [Nullable[datetime]] $Since
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Incremental run-mode tag (#94). Orchestrator uses this to distinguish genuine
# incremental coverage from a FullFallback when -Since is not supplied.
$effectiveRunMode = if ($null -ne $Since) { 'Incremental' } else { 'Full' }

# Dot-source shared modules for Remove-Credentials, Invoke-WithRetry, Invoke-RemoteRepoClone
$sharedDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules' 'shared'
if (-not $sharedDir -or -not (Test-Path $sharedDir)) {
    $sharedDir = Join-Path $PSScriptRoot 'shared'
}
$sanitizePath = Join-Path $sharedDir 'Sanitize.ps1'
if (Test-Path $sanitizePath) { . $sanitizePath }
$missingToolPath = Join-Path $sharedDir 'MissingTool.ps1'
if (Test-Path $missingToolPath) { . $missingToolPath }
$retryPath = Join-Path $sharedDir 'Retry.ps1'
if (Test-Path $retryPath) { . $retryPath }
$remoteClonePath = Join-Path $sharedDir 'RemoteClone.ps1'
if (Test-Path $remoteClonePath) { . $remoteClonePath }
# Bootstrap Invoke-WithTimeout for CLI timeout protection
$cliTimeoutPath = Join-Path $sharedDir 'CliTimeout.ps1'
if (Test-Path $cliTimeoutPath) { . $cliTimeoutPath }

$envelopePath = Join-Path $sharedDir 'New-WrapperEnvelope.ps1'
if (Test-Path $envelopePath) { . $envelopePath }
if (-not (Get-Command New-WrapperEnvelope -ErrorAction SilentlyContinue)) { function New-WrapperEnvelope { param([string]$Source,[string]$Status='Failed',[string]$Message='',[object[]]$FindingErrors=@()) return [PSCustomObject]@{ Source=$Source; SchemaVersion='1.0'; Status=$Status; Message=$Message; Findings=@(); Errors=@($FindingErrors) } } }
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param ([string]$Text) return $Text }
}

function Test-ZizmorInstalled {
    $null -ne (Get-Command zizmor -ErrorAction SilentlyContinue)
}

function Get-ZizmorToolVersion {
    try {
        $versionOutput = & zizmor --version 2>$null
        if (-not $versionOutput) { return '' }
        $line = [string](@($versionOutput) | Select-Object -First 1)
        return (Remove-Credentials $line).Trim()
    } catch {
        return ''
    }
}

function Get-ZizmorRepoCoordinates {
    param(
        [string] $RepositoryPath,
        [string] $RemoteUrl
    )

    $remote = ''
    if ($RemoteUrl) {
        $remote = [string]$RemoteUrl
    } elseif ($RepositoryPath -and (Get-Command git -ErrorAction SilentlyContinue)) {
        try {
            $remote = [string](& git -C $RepositoryPath remote get-url origin 2>$null)
        } catch { $remote = '' }
    }

    $owner = ''
    $repo = ''
    if ($remote) {
        $trimmed = $remote.Trim()
        if ($trimmed -match 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/#?]+?)(?:\.git)?(?:[#?].*)?$') {
            $owner = $Matches['owner']
            $repo = $Matches['repo']
        }
    }

    $sha = ''
    if ($RepositoryPath -and (Get-Command git -ErrorAction SilentlyContinue)) {
        try {
            $sha = [string](& git -C $RepositoryPath rev-parse HEAD 2>$null)
            $sha = $sha.Trim()
        } catch { $sha = '' }
    }

    return @{
        Owner = $owner
        Repo  = $repo
        Sha   = $sha
    }
}

function Resolve-ZizmorPrimaryLocation {
    param([object] $Item)

    $location = @{
        Path      = ''
        StartLine = 0
        EndLine   = 0
    }

    $primary = $null
    if ($Item.PSObject.Properties['locations'] -and $Item.locations) {
        $locs = @($Item.locations)
        if ($locs.Count -gt 0) {
            $primary = $locs[0]
        }
    }
    if (-not $primary -and $Item.PSObject.Properties['location'] -and $Item.location) {
        $primary = $Item.location
    }
    if (-not $primary) { return $location }

    $pathCandidates = @(
        $(if ($primary.PSObject.Properties['symbolic'] -and $primary.symbolic -and $primary.symbolic.PSObject.Properties['key']) { [string]$primary.symbolic.key } else { '' }),
        $(if ($primary.PSObject.Properties['path']) { [string]$primary.path } else { '' }),
        $(if ($primary.PSObject.Properties['file']) { [string]$primary.file } else { '' })
    )
    foreach ($candidate in $pathCandidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $location.Path = $candidate
            break
        }
    }

    $startCandidates = @(
        $(if ($primary.PSObject.Properties['line']) { [int]$primary.line } else { 0 }),
        $(if ($primary.PSObject.Properties['start_line']) { [int]$primary.start_line } else { 0 }),
        $(if ($primary.PSObject.Properties['line_start']) { [int]$primary.line_start } else { 0 }),
        $(if ($primary.PSObject.Properties['range'] -and $primary.range -and $primary.range.PSObject.Properties['start'] -and $primary.range.start -and $primary.range.start.PSObject.Properties['line']) { [int]$primary.range.start.line } else { 0 }),
        $(if ($primary.PSObject.Properties['span'] -and $primary.span -and $primary.span.PSObject.Properties['start'] -and $primary.span.start -and $primary.span.start.PSObject.Properties['line']) { [int]$primary.span.start.line } else { 0 })
    )
    foreach ($candidate in $startCandidates) {
        if ($candidate -gt 0) {
            $location.StartLine = $candidate
            break
        }
    }

    $endCandidates = @(
        $(if ($primary.PSObject.Properties['end_line']) { [int]$primary.end_line } else { 0 }),
        $(if ($primary.PSObject.Properties['line_end']) { [int]$primary.line_end } else { 0 }),
        $(if ($primary.PSObject.Properties['range'] -and $primary.range -and $primary.range.PSObject.Properties['end'] -and $primary.range.end -and $primary.range.end.PSObject.Properties['line']) { [int]$primary.range.end.line } else { 0 }),
        $(if ($primary.PSObject.Properties['span'] -and $primary.span -and $primary.span.PSObject.Properties['end'] -and $primary.span.end -and $primary.span.end.PSObject.Properties['line']) { [int]$primary.span.end.line } else { 0 })
    )
    foreach ($candidate in $endCandidates) {
        if ($candidate -gt 0) {
            $location.EndLine = $candidate
            break
        }
    }
    if ($location.EndLine -le 0 -and $location.StartLine -gt 0) {
        $location.EndLine = $location.StartLine
    }

    return $location
}

function Get-ZizmorRemediationSnippets {
    param([string] $RuleId)

    $rule = ([string]$RuleId).ToLowerInvariant()
    switch ($rule) {
        'template-injection' {
            return @(@{
                    language = 'yaml'
                    before   = @(
                        'steps:'
                        '  - run: echo "${{ github.event.pull_request.title }}"'
                    ) -join "`n"
                    after    = @(
                        'steps:'
                        '  - env:'
                        '      PR_TITLE: ${{ github.event.pull_request.title }}'
                        '    run: echo "$PR_TITLE"'
                    ) -join "`n"
                })
        }
        'unpinned-uses' {
            return @(@{
                    language = 'yaml'
                    before   = 'uses: actions/checkout@v4'
                    after    = 'uses: actions/checkout@<full-40-char-sha> # v4'
                })
        }
        'dangerous-triggers' {
            return @(@{
                    language = 'yaml'
                    before   = @(
                        'on:'
                        '  pull_request_target:'
                    ) -join "`n"
                    after    = @(
                        'on:'
                        '  pull_request:'
                        'jobs:'
                        '  secure-job:'
                        '    if: github.event.pull_request.head.repo.fork == false'
                    ) -join "`n"
                })
        }
        default { return @() }
    }
}

if (-not (Test-ZizmorInstalled)) {
    Write-MissingToolNotice -Tool 'zizmor' -Message "zizmor is not installed. Skipping zizmor scan. Install from https://github.com/woodruffw/zizmor/releases or: pip install zizmor"
    return [PSCustomObject]@{
        Source   = 'zizmor'
        SchemaVersion = '1.0'
        Status   = 'Skipped'
        Message  = 'zizmor CLI not installed. Install from https://github.com/woodruffw/zizmor/releases or: pip install zizmor'
        Findings = @()
        Errors   = @()
        RunMode  = 'Full'
    }
}

# Remote-first: if -RemoteUrl provided, clone it and scan the clone path.
# Otherwise fall back to local -RepoPath.
$cloneInfo = $null
$cleanupClone = $null
try {
    if ($RemoteUrl) {
        if (-not (Get-Command Invoke-RemoteRepoClone -ErrorAction SilentlyContinue)) {
            Write-Warning "RemoteClone helper not loaded; cannot scan remote URL."
            return [PSCustomObject]@{
                Source = 'zizmor'
                SchemaVersion = '1.0'; Status = 'Failed'
                Message = 'RemoteClone helper unavailable'; Findings = @()
                Errors   = @()
                RunMode = $effectiveRunMode
            }
        }
        $cloneInfo = Invoke-RemoteRepoClone -RepoUrl $RemoteUrl
        if (-not $cloneInfo) {
            return [PSCustomObject]@{
                Source = 'zizmor'
                SchemaVersion = '1.0'; Status = 'Failed'
                Message = "Remote clone failed or host not on allow-list: $RemoteUrl"
                Findings = @()
                Errors   = @()
                RunMode = $effectiveRunMode
            }
        }
        $cleanupClone = $cloneInfo.Cleanup
        $RepoPath = $cloneInfo.Path
    }

    if (-not $RepoPath) {
        return [PSCustomObject]@{
            Source = 'zizmor'
            SchemaVersion = '1.0'; Status = 'Skipped'
            Message = 'No -RemoteUrl or -RepoPath provided'; Findings = @()
            Errors   = @()
            RunMode = $effectiveRunMode
        }
    }
    $scanPath = Join-Path $RepoPath $WorkflowPath
    if (-not (Test-Path $scanPath)) {
        Write-Warning "Workflow path not found: $scanPath"
        return [PSCustomObject]@{
            Source   = 'zizmor'
            SchemaVersion = '1.0'
            Status   = 'Skipped'
            Message  = "Workflow path not found: $scanPath"
            Findings = @()
            Errors   = @()
            RunMode  = $effectiveRunMode
        }
    }

    Write-Verbose "Running zizmor for workflow path $scanPath"
    $repoCoordinates = Get-ZizmorRepoCoordinates -RepositoryPath $RepoPath -RemoteUrl $RemoteUrl
    $toolVersion = Get-ZizmorToolVersion

    # zizmor 1.x always writes JSON to stdout (the legacy --output flag was removed,
    # which caused exit code 2 = clap argument parsing failure, see #768). Capture
    # stdout via PowerShell redirection to a temp file. --no-exit-codes prevents
    # finding-severity exit codes (11..14) from being misread as hard failures.
    $reportFile = Join-Path ([System.IO.Path]::GetTempPath()) "zizmor-report-$([guid]::NewGuid().ToString('N')).json"
    $stderrFile = "$reportFile.err"

    try {
        $invokeZizmorScan = {
            $script:zizmorExec = Invoke-WithTimeout -Command 'zizmor' -Arguments @('--format=json', '--no-exit-codes', $scanPath) -TimeoutSec 300
            if ([int]$script:zizmorExec.ExitCode -eq -1) {
                throw (Format-FindingErrorMessage (New-FindingError -Source 'wrapper:zizmor' -Category 'TimeoutExceeded' -Reason 'zizmor timed out after 300 seconds.' -Remediation 'Check repository size or increase timeout.' -Details ''))
            }
            # Write stdout (JSON) to reportFile; stderr to stderrFile
            if ($script:zizmorExec.PSObject.Properties['Stdout'] -and $script:zizmorExec.Stdout) {
                $script:zizmorExec.Stdout | Set-Content -Path $reportFile -Encoding UTF8
            } elseif ($script:zizmorExec.Output) {
                $script:zizmorExec.Output | Set-Content -Path $reportFile -Encoding UTF8
            }
            if ($script:zizmorExec.PSObject.Properties['Stderr'] -and $script:zizmorExec.Stderr) {
                $script:zizmorExec.Stderr | Set-Content -Path $stderrFile -Encoding UTF8
            }
        }
        $useRetry = Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue
        if ($useRetry) {
            Invoke-WithRetry -ScriptBlock $invokeZizmorScan
        } else {
            & $invokeZizmorScan
        }

        $exitCode = [int]$script:zizmorExec.ExitCode

        $stderrText = ''
        if (Test-Path $stderrFile) {
            $stderrText = (Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue) ?? ''
            if ($stderrText) { Write-Verbose "zizmor stderr: $stderrText" }
        }

        $reportExists = Test-Path $reportFile
        $reportSize = if ($reportExists) { (Get-Item $reportFile).Length } else { 0 }

        # Non-zero exit with no report content = hard failure.
        if ($exitCode -ne 0 -and $reportSize -le 0) {
            $sanitizedErr = Remove-Credentials ([string]$stderrText).Trim()
            $msg = "zizmor exited with code $exitCode and produced no report"
            if ($sanitizedErr) { $msg = "$msg`: $sanitizedErr" }
            Write-Warning (Remove-Credentials $msg)
            return [PSCustomObject]@{
                Source   = 'zizmor'
                SchemaVersion = '1.0'
                Status   = 'Failed'
                Message  = Remove-Credentials $msg
                Findings = @()
                Errors   = @()
                RunMode  = $effectiveRunMode
            }
        }

        $json = $null
        if ($reportExists -and $reportSize -gt 0) {
            $jsonText = Get-Content $reportFile -Raw -ErrorAction SilentlyContinue
            if ($jsonText -and $jsonText.Trim()) {
                try {
                    $json = $jsonText | ConvertFrom-Json -ErrorAction Stop
                } catch {
                    Write-Warning (Remove-Credentials "zizmor report JSON parse failed: $_")
                    return [PSCustomObject]@{
                        Source   = 'zizmor'
                        SchemaVersion = '1.0'
                        Status   = 'Failed'
                        Message  = Remove-Credentials "Report JSON parse failed: $_"
                        Findings = @()
                        Errors   = @()
                        RunMode  = $effectiveRunMode
                    }
                }
            } else {
                $json = @()
            }
        } else {
            # exit 0 with empty/no stdout — zizmor found nothing
            $json = @()
        }
    } finally {
        Remove-Item $reportFile -Force -ErrorAction SilentlyContinue
        Remove-Item $stderrFile -Force -ErrorAction SilentlyContinue
    }

    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()

    # zizmor JSON output is an array of finding objects
    $items = if ($json -is [System.Collections.IEnumerable] -and $json -isnot [string]) {
        @($json)
    } elseif ($null -ne $json) {
        @($json)
    } else {
        @()
    }

    foreach ($item in $items) {
        $ruleId = ''
        if ($item.PSObject.Properties['id'] -and $item.id) {
            $ruleId = [string]$item.id
        }

        $desc = ''
        if ($item.PSObject.Properties['desc'] -and $item.desc) {
            $desc = [string]$item.desc
        }

        $rawSev = 'Medium'
        if ($item.PSObject.Properties['severity'] -and $item.severity) {
            $rawSev = [string]$item.severity
        }
        $severity = switch -Regex ($rawSev.ToLowerInvariant()) {
            'critical'        { 'Critical' }
            'high'            { 'High' }
            'medium|moderate' { 'Medium' }
            'low'             { 'Low' }
            'info'            { 'Info' }
            default           { 'Medium' }
        }

        $learnMoreUrl = ''
        if ($item.PSObject.Properties['url'] -and $item.url) {
            $learnMoreUrl = [string]$item.url
        }

        $locInfo = Resolve-ZizmorPrimaryLocation -Item $item
        $filePath = [string]$locInfo.Path
        if (-not $filePath) {
            $filePath = $WorkflowPath
        }
        $filePath = $filePath -replace '\\', '/'
        $filePath = $filePath -replace '^\./', ''

        $severityTier = $severity.ToLowerInvariant()
        $impact = $severity
        $effort = if ($ruleId -eq 'unpinned-uses') { 'Medium' } else { 'Low' }

        $docsUrl = ''
        if ($ruleId) {
            $docsUrl = "https://docs.zizmor.sh/audits/#$ruleId"
        }

        $startLine = [int]$locInfo.StartLine
        $endLine = [int]$locInfo.EndLine
        $lineFragment = ''
        if ($startLine -gt 0) {
            if ($endLine -gt $startLine) {
                $lineFragment = "#L$startLine-L$endLine"
            } else {
                $lineFragment = "#L$startLine"
            }
        }

        $evidenceUris = @()
        if ($repoCoordinates.Owner -and $repoCoordinates.Repo -and $repoCoordinates.Sha -and $filePath) {
            $blobPath = $filePath
            if ($blobPath.StartsWith('/')) { $blobPath = $blobPath.TrimStart('/') }
            $evidenceUris = @("https://github.com/$($repoCoordinates.Owner)/$($repoCoordinates.Repo)/blob/$($repoCoordinates.Sha)/$blobPath$lineFragment")
        }

        $deepLinkUrl = if ($docsUrl) { $docsUrl } elseif (@($evidenceUris).Count -gt 0) { $evidenceUris[0] } else { '' }
        if (-not $learnMoreUrl) { $learnMoreUrl = $deepLinkUrl }

        $baselineTags = @()
        if ($ruleId) { $baselineTags += $ruleId }
        $baselineTags += "severity:$severityTier"

        $mitreTechniques = @()
        switch (($ruleId ?? '').ToLowerInvariant()) {
            'template-injection' { $mitreTechniques = @('T1059') }
            'expression-injection' { $mitreTechniques = @('T1059') }
            'unpinned-uses' { $mitreTechniques = @('T1195.001') }
        }

        $entityRefs = @()
        if ($repoCoordinates.Owner -and $repoCoordinates.Repo -and $filePath) {
            $entityRefs = @("$($repoCoordinates.Owner)/$($repoCoordinates.Repo)/$filePath")
        }

        $remediationSnippets = Get-ZizmorRemediationSnippets -RuleId $ruleId

        $title = if ($ruleId -and $desc) {
            "$ruleId`: $desc"
        } elseif ($ruleId) {
            $ruleId
        } elseif ($desc) {
            $desc
        } else {
            'Unknown zizmor finding'
        }

        $detail = Remove-Credentials $desc
        if ($filePath) {
            $detail = "$detail (file: $filePath)"
        }

        $findings.Add([PSCustomObject]@{
            Id           = [guid]::NewGuid().ToString()
            Category     = 'CI/CD Security'
            RuleId       = $ruleId
            Title        = $title
            Severity     = $severity
            Compliant    = $false
            Detail       = $detail
            Remediation  = ''
            ResourceId   = $filePath
            LearnMoreUrl = $learnMoreUrl
            Pillar       = 'Security'
            Impact       = $impact
            Effort       = $effort
            DeepLinkUrl  = $deepLinkUrl
            RemediationSnippets = @($remediationSnippets)
            EvidenceUris = @($evidenceUris)
            BaselineTags = @($baselineTags)
            MitreTechniques = @($mitreTechniques)
            EntityRefs   = @($entityRefs)
            ToolVersion  = $toolVersion
            StartLine    = $startLine
            EndLine      = $endLine
        })
    }

    return [PSCustomObject]@{
        Source   = 'zizmor'
        SchemaVersion = '1.0'
        Status   = 'Success'
        Message  = ''
        Findings = @($findings)
        Errors   = @()
        ToolVersion = $toolVersion
        RunMode  = $effectiveRunMode
        SinceUtc = if ($null -ne $Since) { ([datetime]$Since).ToUniversalTime().ToString('o') } else { $null }
    }
} catch {
    Write-Warning (Remove-Credentials "zizmor scan failed: $_")
    return [PSCustomObject]@{
        Source   = 'zizmor'
        SchemaVersion = '1.0'
        Status   = 'Failed'
        Message  = Remove-Credentials "$_"
        Findings = @()
        Errors   = @()
        RunMode  = $effectiveRunMode
    }
} finally {
    if ($cleanupClone) {
        try { & $cleanupClone } catch { Write-Verbose "zizmor clone cleanup failed: $(Remove-Credentials -Text ([string]$_.Exception.Message))" }
    }
}
