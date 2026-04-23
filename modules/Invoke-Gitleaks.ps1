#Requires -Version 7.0
<#
.SYNOPSIS
    Wrapper for gitleaks CLI (secrets scanner).
.DESCRIPTION
    Runs the gitleaks CLI against a git repository to detect leaked secrets
    such as API keys, tokens, and passwords in git history.
    If gitleaks is not installed, writes a warning and returns an empty result.
    Never throws -- designed for graceful degradation in the orchestrator.

    Security: The --redact flag ensures the report file never contains plaintext
    secret values. Secret/Match fields are also stripped during post-processing
    as a defense-in-depth layer. The report is written to the system temp
    directory (not inside the scanned repo).
.PARAMETER RepoPath
    Path to the repository to scan. Defaults to the current directory.
.PARAMETER NoGit
    Switch for scanning non-git directories (uses --no-git flag).
.PARAMETER GitleaksConfigPath
    Optional local path to a gitleaks TOML config file.
    When provided, the wrapper passes --config <path> to gitleaks.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param (
    [string] $RepoPath = '.',

    [switch] $NoGit,

    [string] $RemoteUrl,

    [string] $GitleaksConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
$errorsPath = Join-Path $sharedDir 'Errors.ps1'
if (Test-Path $errorsPath) { . $errorsPath }

if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param ([string]$Text) return $Text }
}
if (-not (Get-Command New-FindingError -ErrorAction SilentlyContinue)) {
    function New-FindingError { param([string]$Source,[string]$Category,[string]$Reason,[string]$Remediation,[string]$Details) return [pscustomobject]@{ Source=$Source; Category=$Category; Reason=$Reason; Remediation=$Remediation; Details=$Details } }
}
if (-not (Get-Command Format-FindingErrorMessage -ErrorAction SilentlyContinue)) {
    function Format-FindingErrorMessage {
        param([Parameter(Mandatory)]$FindingError)
        $line = "[{0}] {1}: {2}" -f $FindingError.Source, $FindingError.Category, $FindingError.Reason
        if ($FindingError.Remediation) { $line += " Action: $($FindingError.Remediation)" }
        return $line
    }
}

function Test-GitleaksInstalled {
    $null -ne (Get-Command gitleaks -ErrorAction SilentlyContinue)
}

function Get-GitleaksToolVersion {
    try {
        $rawVersion = gitleaks version 2>&1
        if ($LASTEXITCODE -ne 0) { return '' }
        $versionText = if ($rawVersion -is [array]) { ($rawVersion -join ' ') } else { [string]$rawVersion }
        $match = [regex]::Match($versionText, '(\d+\.\d+\.\d+(?:[-+][A-Za-z0-9\.-]+)?)')
        if ($match.Success) { return $match.Groups[1].Value }
        return $versionText.Trim()
    } catch {
        return ''
    }
}

function Get-GitRemoteUrl {
    param (
        [Parameter(Mandatory)]
        [string] $RepositoryPath
    )

    try {
        $raw = git -C $RepositoryPath config --get remote.origin.url 2>$null
        if ($LASTEXITCODE -ne 0) { return '' }
        $value = if ($raw -is [array]) { ($raw | Select-Object -First 1) } else { [string]$raw }
        return [string]$value
    } catch {
        return ''
    }
}

function Resolve-RepositoryMetadata {
    param (
        [string] $RemoteCandidate
    )

    $candidate = [string]$RemoteCandidate
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return [PSCustomObject]@{
            Host         = 'github.com'
            Owner        = 'local'
            Name         = 'local'
            EntityId     = 'github.com/local/local'
            RepositoryId = 'github.com/local/local'
            RepositoryUrl = 'https://github.com/local/local'
        }
    }

    $normalized = $candidate.Trim() -replace '\.git$', ''
    $repoHost = ''
    $owner = ''
    $name = ''

    if ($normalized -match '^https?://([^/]+)/([^/]+)/([^/?#]+)$') {
        $repoHost = $matches[1]
        $owner = $matches[2]
        $name = $matches[3]
    } elseif ($normalized -match '^git@([^:]+):([^/]+)/([^/?#]+)$') {
        $repoHost = $matches[1]
        $owner = $matches[2]
        $name = $matches[3]
    } elseif ($normalized -match '^([^/]+)/([^/]+)/([^/]+)$') {
        $repoHost = $matches[1]
        $owner = $matches[2]
        $name = $matches[3]
    }

    if ([string]::IsNullOrWhiteSpace($repoHost) -or [string]::IsNullOrWhiteSpace($owner) -or [string]::IsNullOrWhiteSpace($name)) {
        return [PSCustomObject]@{
            Host         = 'github.com'
            Owner        = 'local'
            Name         = 'local'
            EntityId     = 'github.com/local/local'
            RepositoryId = 'github.com/local/local'
            RepositoryUrl = 'https://github.com/local/local'
        }
    }

    $repoHost = $repoHost.ToLowerInvariant()
    $owner = $owner.ToLowerInvariant()
    $name = $name.ToLowerInvariant()
    [PSCustomObject]@{
        Host          = $repoHost
        Owner         = $owner
        Name          = $name
        EntityId      = "$repoHost/$owner/$name"
        RepositoryId  = "$repoHost/$owner/$name"
        RepositoryUrl = "https://$repoHost/$owner/$name"
    }
}

function Get-GitleaksSeverity {
    param (
        [string] $RuleId,
        [string] $Description,
        [string[]] $Tags
    )

    $material = @($RuleId, $Description, (@($Tags) -join ' ')) -join ' '
    if ($material -match '(?i)aws|azure|gcp|google|cloud|access[-_\s]?key|secret[-_\s]?access[-_\s]?key|service[-_\s]?account|connection[-_\s]?string|storage[-_\s]?key') {
        return 'Critical'
    }
    return 'Medium'
}

function Get-GitleaksFrameworks {
    param (
        [string] $RuleId,
        [string] $Description,
        [string[]] $Tags
    )

    $frameworks = [System.Collections.Generic.List[hashtable]]::new()
    $material = @($RuleId, $Description, (@($Tags) -join ' ')) -join ' '

    if ($material -match '(?i)access|auth|credential|token|key|password|secret') {
        $frameworks.Add(@{ kind = 'NIST 800-53'; controlId = 'IA' }) | Out-Null
        $frameworks.Add(@{ kind = 'ISO 27001'; controlId = 'A.9' }) | Out-Null
    }
    if ($material -match '(?i)access|permission|privilege|rbac') {
        $frameworks.Add(@{ kind = 'NIST 800-53'; controlId = 'AC' }) | Out-Null
    }
    if ($material -match '(?i)audit|log|trace') {
        $frameworks.Add(@{ kind = 'NIST 800-53'; controlId = 'AU' }) | Out-Null
    }

    return @($frameworks)
}

function Get-BaselineTags {
    param (
        [string] $RuleId,
        [string[]] $Tags
    )

    $output = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

    if (-not [string]::IsNullOrWhiteSpace($RuleId)) {
        $ruleTag = "gitleaks:rule:$($RuleId.ToLowerInvariant())"
        if ($seen.Add($ruleTag)) { $output.Add($ruleTag) | Out-Null }
    }

    $hasSecretTag = $false
    foreach ($tag in @($Tags)) {
        if ([string]::IsNullOrWhiteSpace([string]$tag)) { continue }
        $normalizedTag = [string]$tag
        if ($normalizedTag -match '(?i)secret') { $hasSecretTag = $true }
        $tagValue = "gitleaks:tag:$($normalizedTag.Trim().ToLowerInvariant())"
        if ($seen.Add($tagValue)) { $output.Add($tagValue) | Out-Null }
    }

    if (-not $hasSecretTag) {
        $secretTag = 'gitleaks:tag:secret'
        if ($seen.Add($secretTag)) { $output.Add($secretTag) | Out-Null }
    }

    return @($output)
}

function Get-EvidenceUris {
    param (
        [Parameter(Mandatory)]
        [pscustomobject] $RepositoryMeta,
        [string] $FilePath,
        [int] $StartLine,
        [string] $Commit
    )

    $uris = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($RepositoryMeta.RepositoryUrl)) { return @() }

    if (-not [string]::IsNullOrWhiteSpace($Commit)) {
        $uris.Add("$($RepositoryMeta.RepositoryUrl)/commit/$Commit") | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($FilePath) -and -not [string]::IsNullOrWhiteSpace($Commit)) {
        $normalizedFile = $FilePath.Trim() -replace '\\', '/'
        $lineFragment = if ($StartLine -gt 0) { "#L$StartLine" } else { '' }
        $uris.Add("$($RepositoryMeta.RepositoryUrl)/blob/$Commit/$normalizedFile$lineFragment") | Out-Null
    }

    return @($uris)
}

function Get-EntityRefs {
    param (
        [Parameter(Mandatory)]
        [pscustomobject] $RepositoryMeta,
        [string] $Commit,
        [string] $FilePath
    )

    $refs = [System.Collections.Generic.List[string]]::new()
    $refs.Add($RepositoryMeta.EntityId) | Out-Null

    if (-not [string]::IsNullOrWhiteSpace($Commit)) {
        $refs.Add("commit:$($RepositoryMeta.Owner)/$($RepositoryMeta.Name)/$Commit") | Out-Null
    }

    $normalizedFile = [string]$FilePath
    if (-not [string]::IsNullOrWhiteSpace($normalizedFile)) {
        $normalizedFile = $normalizedFile -replace '\\', '/'
        if ($normalizedFile -match '(?i)^\.github/workflows/[^/]+\.ya?ml$') {
            $refs.Add("workflow:$($RepositoryMeta.Owner)/$($RepositoryMeta.Name)/$normalizedFile") | Out-Null
        }
    }

    return @($refs)
}

function Get-GitleaksRemediationSnippets {
    param (
        [Parameter(Mandatory)]
        [pscustomobject] $RepositoryMeta
    )

    return @(
        @{
            language = 'text'
            code = "1) Revoke or rotate the exposed credential immediately. 2) Replace the secret with a secure reference (GitHub Actions secret, Azure Key Vault, or managed identity). 3) Remove the secret from Git history and force rotate any dependent systems."
        },
        @{
            language = 'bash'
            code = "gh api -X PATCH repos/$($RepositoryMeta.Owner)/$($RepositoryMeta.Name) --raw-field security_and_analysis[secret_scanning][status]=enabled --raw-field security_and_analysis[secret_scanning_push_protection][status]=enabled"
        }
    )
}

function Test-GitleaksConfigDisablesDefaults {
    param (
        [Parameter(Mandatory)]
        [string] $ConfigPath
    )

    $content = Get-Content -Path $ConfigPath -Raw -ErrorAction Stop
    $extendMatch = [regex]::Match($content, '(?ms)^\s*\[extend\]\s*(?<body>.*?)(?=^\s*\[[^\[]|\z)')
    if (-not $extendMatch.Success) {
        return $false
    }

    $extendBody = [string]$extendMatch.Groups['body'].Value
    $usesNoDefaults = $extendBody -match '(?im)^\s*useDefault\s*=\s*false\s*$'
    if (-not $usesNoDefaults) {
        return $false
    }

    $hasCustomRules = $content -match '(?m)^\s*\[\[rules\]\]\s*$'
    return (-not $hasCustomRules)
}

function Resolve-GitleaksConfig {
    param (
        [Parameter(Mandatory)]
        [string] $ConfigPath
    )

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        return $null
    }

    if ($ConfigPath -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        throw (Format-FindingErrorMessage (New-FindingError -Source 'wrapper:gitleaks' -Category 'InvalidParameter' -Reason "Gitleaks config path must be a local file path. URLs are not allowed: '$ConfigPath'" -Remediation 'Provide a local .toml file path via -GitleaksConfigPath.'))
    }

    if ([System.IO.Path]::GetExtension($ConfigPath).ToLowerInvariant() -ne '.toml') {
        throw (Format-FindingErrorMessage (New-FindingError -Source 'wrapper:gitleaks' -Category 'InvalidParameter' -Reason "Gitleaks config path must point to a .toml file: '$ConfigPath'" -Remediation 'Use a gitleaks TOML config file for -GitleaksConfigPath.'))
    }

    if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
        throw (Format-FindingErrorMessage (New-FindingError -Source 'wrapper:gitleaks' -Category 'NotFound' -Reason "Gitleaks config file not found: '$ConfigPath'" -Remediation 'Verify the -GitleaksConfigPath value resolves to an existing file.'))
    }

    $resolvedConfigPath = Resolve-Path -Path $ConfigPath -ErrorAction Stop | Select-Object -ExpandProperty Path
    [PSCustomObject]@{
        Path                                  = $resolvedConfigPath
        DisablesDefaultsWithoutCustomRules    = (Test-GitleaksConfigDisablesDefaults -ConfigPath $resolvedConfigPath)
    }
}

if (-not (Test-GitleaksInstalled)) {
    Write-MissingToolNotice -Tool 'gitleaks' -Message "gitleaks is not installed. Skipping gitleaks scan. Install from https://github.com/gitleaks/gitleaks/releases"
    return [PSCustomObject]@{
        Source   = 'gitleaks'
        SchemaVersion = '1.0'
        Status   = 'Skipped'
        Message  = 'gitleaks CLI not installed. Install from https://github.com/gitleaks/gitleaks/releases'
        Findings = @()
    }
}

$resolvedConfig = $null
if (-not [string]::IsNullOrWhiteSpace($GitleaksConfigPath)) {
    $resolvedConfig = Resolve-GitleaksConfig -ConfigPath $GitleaksConfigPath
}

$cloneInfo = $null
$cleanupClone = $null
$toolVersion = Get-GitleaksToolVersion
try {
    if ($RemoteUrl) {
        if (-not (Get-Command Invoke-RemoteRepoClone -ErrorAction SilentlyContinue)) {
            Write-Warning "RemoteClone helper not loaded; cannot scan remote URL."
            return [PSCustomObject]@{
                Source = 'gitleaks'
                SchemaVersion = '1.0'; Status = 'Failed'
                Message = 'RemoteClone helper unavailable'; Findings = @()
            }
        }
        $cloneInfo = Invoke-RemoteRepoClone -RepoUrl $RemoteUrl
        if (-not $cloneInfo) {
            return [PSCustomObject]@{
                Source = 'gitleaks'
                SchemaVersion = '1.0'; Status = 'Failed'
                Message = "Remote clone failed or host not on allow-list: $RemoteUrl"
                Findings = @()
            }
        }
        $cleanupClone = $cloneInfo.Cleanup
        $RepoPath = $cloneInfo.Path
    }

    $resolvedPath = Resolve-Path $RepoPath -ErrorAction Stop | Select-Object -ExpandProperty Path
    Write-Verbose "Running gitleaks for path $resolvedPath"

    $remoteCandidate = if ($RemoteUrl) { $RemoteUrl } elseif ($cloneInfo -and $cloneInfo.Url) { [string]$cloneInfo.Url } else { Get-GitRemoteUrl -RepositoryPath $resolvedPath }
    $repositoryMeta = Resolve-RepositoryMetadata -RemoteCandidate $remoteCandidate

    # Write report to system temp dir — never inside the scanned repo
    $reportFile = Join-Path ([System.IO.Path]::GetTempPath()) "gitleaks-report-$([guid]::NewGuid().ToString('N')).json"

    try {
        # --redact: gitleaks replaces secret values with REDACTED in the report so plaintext secrets are never written to disk
        $gitleaksArgs = @('detect', '--source', $resolvedPath, '--report-format', 'json', '--report-path', $reportFile, '--no-banner', '--redact', '--exit-code', '0')
        if ($NoGit) {
            $gitleaksArgs += '--no-git'
        }
        if ($resolvedConfig) {
            $gitleaksArgs += @('--config', $resolvedConfig.Path)
        }

        $useRetry = Get-Command Invoke-WithRetry -ErrorAction SilentlyContinue
        if ($useRetry) {
            Invoke-WithRetry -ScriptBlock {
                $stderrLines = & gitleaks @gitleaksArgs 2>&1 | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }
                if ($stderrLines) {
                    Write-Verbose "gitleaks stderr: $($stderrLines -join '; ')"
                }
            }
        } else {
            $stderrLines = & gitleaks @gitleaksArgs 2>&1 | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }
            if ($stderrLines) {
                Write-Verbose "gitleaks stderr: $($stderrLines -join '; ')"
            }
        }

        $exitCode = $LASTEXITCODE

        # Validate: non-zero exit code with no report = hard failure
        if ($exitCode -ne 0 -and -not (Test-Path $reportFile)) {
            Write-Warning (Remove-Credentials "gitleaks exited with code $exitCode and produced no report")
            return [PSCustomObject]@{
                Source   = 'gitleaks'
                SchemaVersion = '1.0'
                Status   = 'Failed'
                Message  = Remove-Credentials "gitleaks exited with code $exitCode and produced no report"
                Findings = @()
            }
        }

        $json = @()
        if (Test-Path $reportFile) {
            $jsonText = Get-Content $reportFile -Raw -ErrorAction SilentlyContinue
            if ($jsonText) {
                try {
                    $json = $jsonText | ConvertFrom-Json -ErrorAction Stop
                } catch {
                    Write-Warning (Remove-Credentials "gitleaks report JSON parse failed: $_")
                    return [PSCustomObject]@{
                        Source   = 'gitleaks'
                        SchemaVersion = '1.0'
                        Status   = 'Failed'
                        Message  = Remove-Credentials "Report JSON parse failed: $_"
                        Findings = @()
                    }
                }
            }
        } elseif ($exitCode -eq 0) {
            # exit 0 but no report file — gitleaks found nothing; treat as success
            $json = @()
        }
    } finally {
        Remove-Item $reportFile -Force -ErrorAction SilentlyContinue
    }

    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()
    if ($resolvedConfig) {
        $sanitizedConfigPath = Remove-Credentials ([string]$resolvedConfig.Path)

        if ($resolvedConfig.DisablesDefaultsWithoutCustomRules) {
            $findings.Add([PSCustomObject]@{
                Id           = [guid]::NewGuid().ToString()
                RuleId       = 'gitleaks.config.disable-defaults'
                Category     = 'Configuration'
                Title        = 'Gitleaks pattern override disables all built-in rules'
                Severity     = 'High'
                Compliant    = $false
                Detail       = Remove-Credentials "Custom gitleaks config '$sanitizedConfigPath' sets [extend] useDefault = false without custom [[rules]]. This creates a high risk of missed secrets."
                Remediation  = 'Set useDefault = true or add at least one vetted custom [[rules]] entry before scanning.'
                ResourceId   = $sanitizedConfigPath
                LearnMoreUrl = 'https://github.com/gitleaks/gitleaks'
                Pillar       = 'Security'
                Impact       = 'High'
                Effort       = 'Low'
                DeepLinkUrl  = 'https://github.com/gitleaks/gitleaks/blob/master/config/gitleaks.toml'
                RemediationSnippets = @(Get-GitleaksRemediationSnippets -RepositoryMeta $repositoryMeta)
                BaselineTags = @('gitleaks:config:custom','gitleaks:tag:secret')
                Frameworks   = @(@{ kind = 'NIST 800-53'; controlId = 'IA' }, @{ kind = 'ISO 27001'; controlId = 'A.9' })
                EntityRefs   = @($repositoryMeta.EntityId)
                ToolVersion  = $toolVersion
            })
        }

        $findings.Add([PSCustomObject]@{
            Id           = [guid]::NewGuid().ToString()
            RuleId       = 'gitleaks.config.custom-applied'
            Category     = 'Configuration'
            Title        = 'Custom gitleaks config applied'
            Severity     = 'Info'
            Compliant    = $true
            Detail       = Remove-Credentials "Applied custom gitleaks config: '$sanitizedConfigPath'."
            Remediation  = 'Review custom allowlist and rule overrides regularly to keep secret detection coverage strong.'
            ResourceId   = $sanitizedConfigPath
            LearnMoreUrl = 'https://github.com/gitleaks/gitleaks'
            Pillar       = 'Security'
            Impact       = 'Low'
            Effort       = 'Low'
            DeepLinkUrl  = 'https://github.com/gitleaks/gitleaks/blob/master/config/gitleaks.toml'
            RemediationSnippets = @(Get-GitleaksRemediationSnippets -RepositoryMeta $repositoryMeta)
            BaselineTags = @('gitleaks:config:custom','gitleaks:tag:secret')
            Frameworks   = @(@{ kind = 'NIST 800-53'; controlId = 'IA' }, @{ kind = 'ISO 27001'; controlId = 'A.9' })
            EntityRefs   = @($repositoryMeta.EntityId)
            ToolVersion  = $toolVersion
        })
    }

    $items = if ($json -is [System.Collections.IEnumerable] -and $json -isnot [string]) {
        @($json)
    } elseif ($null -ne $json) {
        @($json)
    } else {
        @()
    }

    foreach ($item in $items) {
        $ruleId = ''
        if ($item.PSObject.Properties['RuleID'] -and $item.RuleID) {
            $ruleId = [string]$item.RuleID
        }

        $description = ''
        if ($item.PSObject.Properties['Description'] -and $item.Description) {
            $description = [string]$item.Description
        }

        $filePath = ''
        if ($item.PSObject.Properties['File'] -and $item.File) {
            $filePath = [string]$item.File
        }

        $startLine = 0
        if ($item.PSObject.Properties['StartLine'] -and $item.StartLine) {
            $startLine = [int]$item.StartLine
        }

        $commit = ''
        if ($item.PSObject.Properties['Commit'] -and $item.Commit) {
            $commit = [string]$item.Commit
        }

        $fingerprint = ''
        if ($item.PSObject.Properties['Fingerprint'] -and $item.Fingerprint) {
            $fingerprint = [string]$item.Fingerprint
        }

        # Strip Secret/Match fields — defense-in-depth; --redact already replaces values in the report

        # Severity: Secret-type findings → High, everything else → Medium
        $tags = @()
        if ($item.PSObject.Properties['Tags'] -and $item.Tags) { $tags = @($item.Tags | ForEach-Object { [string]$_ }) }
        $severity = Get-GitleaksSeverity -RuleId $ruleId -Description $description -Tags $tags
        $frameworks = @(Get-GitleaksFrameworks -RuleId $ruleId -Description $description -Tags $tags)
        $baselineTags = @(Get-BaselineTags -RuleId $ruleId -Tags $tags)
        $evidenceUris = @(Get-EvidenceUris -RepositoryMeta $repositoryMeta -FilePath $filePath -StartLine $startLine -Commit $commit)
        $entityRefs = @(Get-EntityRefs -RepositoryMeta $repositoryMeta -Commit $commit -FilePath $filePath)
        $ruleAnchor = if ($ruleId) { "#rule-$([uri]::EscapeDataString($ruleId.ToLowerInvariant()))" } else { '' }
        $deepLinkUrl = "https://github.com/gitleaks/gitleaks/blob/master/config/gitleaks.toml$ruleAnchor"

        $title = if ($description -and $filePath) {
            "$description found in $filePath"
        } elseif ($description) {
            $description
        } elseif ($ruleId) {
            "Secret detected: $ruleId"
        } else {
            'Secret detected'
        }

        $commitRef = if ($commit) { $commit.Substring(0, [Math]::Min(7, $commit.Length)) } else { '' }
        $detail = "Rule '$ruleId' matched in file $filePath at line $startLine."
        if ($commitRef) {
            $detail += " Commit: $commitRef."
        }
        $detail = Remove-Credentials $detail

        $findings.Add([PSCustomObject]@{
            Id           = if ($fingerprint) { $fingerprint } else { [guid]::NewGuid().ToString() }
            RuleId       = $ruleId
            Category     = 'Secret Detection'
            Title        = $title
            Severity     = $severity
            Compliant    = $false
            Detail       = $detail
            Remediation  = 'Rotate the exposed credential and remove it from git history using git-filter-repo or BFG Repo-Cleaner.'
            ResourceId   = $filePath
            LearnMoreUrl = 'https://github.com/gitleaks/gitleaks'
            Pillar       = 'Security'
            Impact       = if ($severity -eq 'Critical') { 'High' } else { 'Medium' }
            Effort       = 'Low'
            DeepLinkUrl  = $deepLinkUrl
            RemediationSnippets = @(Get-GitleaksRemediationSnippets -RepositoryMeta $repositoryMeta)
            EvidenceUris = $evidenceUris
            BaselineTags = $baselineTags
            Frameworks   = $frameworks
            EntityRefs   = $entityRefs
            ToolVersion  = $toolVersion
        })
    }

    return [PSCustomObject]@{
        Source   = 'gitleaks'
        SchemaVersion = '1.0'
        Status   = 'Success'
        Message  = ''
        RepositoryId = $repositoryMeta.RepositoryId
        RepositoryEntityId = $repositoryMeta.EntityId
        RepositoryUrl = $repositoryMeta.RepositoryUrl
        ToolVersion = $toolVersion
        Findings = $findings
    }
} catch {
    Write-Warning (Remove-Credentials "gitleaks scan failed: $_")
    return [PSCustomObject]@{
        Source   = 'gitleaks'
        SchemaVersion = '1.0'
        Status   = 'Failed'
        Message  = Remove-Credentials "$_"
        Findings = @()
    }
} finally {
    if ($cleanupClone) {
        try { & $cleanupClone } catch { Write-Verbose "gitleaks clone cleanup failed: $(Remove-Credentials -Text ([string]$_.Exception.Message))" }
    }
}
