#Requires -Version 7.4
<#
.SYNOPSIS
    Shared adapter loader for IaC validation tools.
.DESCRIPTION
    Exports Invoke-IaCAdapter which dispatches to flavour-specific validation
    helpers (bicep, terraform). Each adapter returns a v1 wrapper envelope
    (SchemaVersion 1.0, Status, Findings[]) consistent with other wrappers.

    All external process launches go through Invoke-WithTimeout (300s hard cap).
    Invoke-WithTimeout is required; the adapter fails closed if it is unavailable.
    All written output passes through Remove-Credentials.
    All clones go through Invoke-RemoteRepoClone (cloud-first invariant).
#>
[CmdletBinding()]
param ()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Dot-source shared modules
$sharedDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'shared'
if (-not (Test-Path $sharedDir)) {
    $sharedDir = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'modules' 'shared'
}
$sanitizePath = Join-Path $sharedDir 'Sanitize.ps1'
if (Test-Path $sanitizePath) { . $sanitizePath }
$retryPath = Join-Path $sharedDir 'Retry.ps1'
if (Test-Path $retryPath) { . $retryPath }
$remoteClonePath = Join-Path $sharedDir 'RemoteClone.ps1'
if (Test-Path $remoteClonePath) { . $remoteClonePath }
# Installer.ps1 provides Invoke-WithTimeout (300s hard cap on external processes)
$installerPath = Join-Path $sharedDir 'Installer.ps1'
if (Test-Path $installerPath) { . $installerPath }

if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param ([string]$Text) return $Text }
}

$script:IaCTimeoutSec = 300

# Fail closed if the timeout helper is unavailable
function Assert-TimeoutHelperLoaded {
    if (-not (Get-Command Invoke-WithTimeout -ErrorAction SilentlyContinue)) {
        throw "Required safety primitive Invoke-WithTimeout is not loaded. Ensure Installer.ps1 is available."
    }
}

function Invoke-IaCAdapter {
    <#
    .SYNOPSIS
        Dispatch to a flavour-specific IaC validation adapter.
    .PARAMETER Flavour
        IaC flavour: bicep or terraform.
    .PARAMETER RepoPath
        Local path to the repository root containing IaC files.
    .PARAMETER RemoteUrl
        Remote repository URL; cloned via RemoteClone.ps1 if provided.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('bicep', 'terraform')]
        [string] $Flavour,

        [string] $RepoPath,

        [string] $RemoteUrl,

        [string] $SourceRepoUrl = ''
    )

    $cloneInfo = $null
    $cleanupClone = $null
    try {
        if ($RemoteUrl) {
            if (-not (Get-Command Invoke-RemoteRepoClone -ErrorAction SilentlyContinue)) {
                Write-Warning "RemoteClone helper not loaded; cannot scan remote URL."
                return [PSCustomObject]@{
                    Source = "iac-$Flavour"; Status = 'Failed'
                    SchemaVersion = '1.0'
                    Message = 'RemoteClone helper unavailable'; Findings = @()
                }
            }
            $cloneInfo = Invoke-RemoteRepoClone -RepoUrl $RemoteUrl
            if (-not $cloneInfo) {
                return [PSCustomObject]@{
                    Source = "iac-$Flavour"; Status = 'Failed'
                    SchemaVersion = '1.0'
                    Message = "Remote clone failed or host not on allow-list: $RemoteUrl"
                    Findings = @()
                }
            }
            $cleanupClone = $cloneInfo.Cleanup
            $RepoPath = $cloneInfo.Path
        }

        if (-not $RepoPath) {
            return [PSCustomObject]@{
                Source = "iac-$Flavour"; Status = 'Skipped'
                SchemaVersion = '1.0'
                Message = 'No -RepoPath or -RemoteUrl provided'; Findings = @()
            }
        }

        switch ($Flavour) {
            'bicep' { return Invoke-BicepValidation -RepoPath $RepoPath }
            'terraform' {
                $sourceUrl = if ($RemoteUrl) { $RemoteUrl } else { $SourceRepoUrl }
                return Invoke-TerraformValidation -RepoPath $RepoPath -SourceRepoUrl $sourceUrl
            }
            default {
                return [PSCustomObject]@{
                    Source = "iac-$Flavour"; Status = 'Skipped'
                    SchemaVersion = '1.0'
                    Message = "Unsupported IaC flavour: $Flavour"; Findings = @()
                }
            }
        }
    } catch {
        Write-Warning (Remove-Credentials "IaC adapter ($Flavour) failed: $_")
        return [PSCustomObject]@{
            Source = "iac-$Flavour"; Status = 'Failed'
            SchemaVersion = '1.0'
            Message = Remove-Credentials "$_"; Findings = @()
        }
    } finally {
        if ($cleanupClone) {
            try { & $cleanupClone } catch {
                Write-Verbose "IaC adapter clone cleanup failed: $(Remove-Credentials -Text ([string]$_.Exception.Message))"
            }
        }
    }
}

function Invoke-BicepValidation {
    <#
    .SYNOPSIS
        Run bicep build validation against all .bicep files in a repo.
    .DESCRIPTION
        Each file is compiled via Invoke-WithTimeout (300s hard cap).
        Generated ARM JSON artefacts are cleaned up in a finally block
        so the user's repo is never polluted.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $RepoPath
    )

    function Get-BicepDiagnosticMetadata {
        param (
            [string] $LineText,
            [string] $FallbackPath
        )

        $metadata = [ordered]@{
            RuleId      = ''
            Level       = ''
            RelativePath = $FallbackPath
            LineNumber  = ''
            Message     = $LineText
        }

        $pattern = '^(?<path>.+?)\((?<line>\d+)(?:,\d+)?\)\s*:\s*(?<level>Error|Warning|Info)\s+(?<code>[A-Z]{2,}\d+)\s*:\s*(?<message>.+)$'
        $match = [regex]::Match($LineText.Trim(), $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            $rawPath = [string]$match.Groups['path'].Value
            $metadata.RuleId = [string]$match.Groups['code'].Value.ToUpperInvariant()
            $metadata.Level = [string]$match.Groups['level'].Value
            $metadata.LineNumber = [string]$match.Groups['line'].Value
            $metadata.Message = [string]$match.Groups['message'].Value
            if (-not [string]::IsNullOrWhiteSpace($rawPath)) {
                try {
                    $resolved = $rawPath
                    if ([System.IO.Path]::IsPathRooted($rawPath)) {
                        $resolved = $rawPath.Substring($RepoPath.Length).TrimStart('\', '/')
                    }
                    $metadata.RelativePath = $resolved
                } catch {
                    $metadata.RelativePath = $FallbackPath
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace([string]$metadata.RuleId)) {
            $codeMatch = [regex]::Match($LineText, '\b(BCP\d{3}|AZR-[A-Z0-9-]+)\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($codeMatch.Success) { $metadata.RuleId = [string]$codeMatch.Groups[1].Value.ToUpperInvariant() }
        }

        if ([string]::IsNullOrWhiteSpace([string]$metadata.Level)) {
            if ($LineText -match '(?i)\berror\b') { $metadata.Level = 'Error' }
            elseif ($LineText -match '(?i)\bwarning\b') { $metadata.Level = 'Warning' }
            else { $metadata.Level = 'Info' }
        }

        return [PSCustomObject]$metadata
    }

    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()
    $bicepFiles = @(Get-ChildItem -Path $RepoPath -Filter '*.bicep' -Recurse -File -ErrorAction SilentlyContinue)

    if ($bicepFiles.Count -eq 0) {
        return [PSCustomObject]@{
            Source = 'bicep-iac'
            SchemaVersion = '1.0'; Status = 'Success'
            Message = 'No .bicep files found'; Findings = @()
        }
    }

    $generatedJsonFiles = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($file in $bicepFiles) {
            $relativePath = $file.FullName.Substring($RepoPath.Length).TrimStart('\', '/')
            # Track the ARM JSON that bicep build will generate
            $jsonPath = [System.IO.Path]::ChangeExtension($file.FullName, '.json')
            $generatedJsonFiles.Add($jsonPath)

            try {
                Assert-TimeoutHelperLoaded
                $result = Invoke-WithTimeout -Command 'bicep' -Arguments @('build', $file.FullName) -TimeoutSec $script:IaCTimeoutSec
                $exitCode = $result.ExitCode
                $outputText = $result.Output

                if ($exitCode -ne 0) {
                    $errorLines = @($outputText -split "`n" | Where-Object { $_ -match '(Error|Warning)\s' })

                    foreach ($line in $errorLines) {
                        $lineStr = Remove-Credentials $line
                        $diag = Get-BicepDiagnosticMetadata -LineText $lineStr -FallbackPath $relativePath
                        $severity = if ($diag.Level -match '^(?i)error$') { 'Error' }
                                    elseif ($diag.Level -match '^(?i)warning$') { 'Warning' }
                                    else { 'Info' }
                        $category = 'IaC Validation'
                        if ($lineStr -match '(?i)security|secret|password|keyvault|identity|rbac|tls|encrypt') { $category = 'Security' }
                        elseif ($lineStr -match '(?i)cost|sku|pricing|size') { $category = 'Cost' }
                        elseif ($lineStr -match '(?i)availability|zone|region|failover|backup') { $category = 'Reliability' }
                        elseif ($lineStr -match '(?i)performance|throughput|latency|concurrency') { $category = 'Performance' }
                        elseif ($lineStr -match '(?i)diagnostic|logging|monitor|governance|policy') { $category = 'Operations' }

                        $findings.Add([PSCustomObject]@{
                            Id          = [guid]::NewGuid().ToString()
                            RuleId      = $diag.RuleId
                            Level       = $diag.Level
                            Category    = $category
                            Title       = "Bicep diagnostic $($diag.RuleId): $($diag.RelativePath)"
                            Severity    = $severity
                            Compliant   = $false
                            Detail      = $lineStr.Trim()
                            Remediation = "Fix rule $($diag.RuleId) in $($diag.RelativePath)"
                            ResourceId  = $diag.RelativePath
                            LearnMoreUrl = 'https://learn.microsoft.com/azure/azure-resource-manager/bicep/overview'
                            LineNumber  = $diag.LineNumber
                        })
                    }

                    if ($errorLines.Count -eq 0) {
                        $findings.Add([PSCustomObject]@{
                            Id          = [guid]::NewGuid().ToString()
                            RuleId      = 'BICEP-BUILD-FAILED'
                            Level       = 'Error'
                            Category    = 'IaC Validation'
                            Title       = "Bicep build failed: $relativePath"
                            Severity    = 'Error'
                            Compliant   = $false
                            Detail      = Remove-Credentials $outputText
                            Remediation = "Fix the Bicep file at $relativePath"
                            ResourceId  = $relativePath
                            LearnMoreUrl = 'https://learn.microsoft.com/azure/azure-resource-manager/bicep/overview'
                        })
                    }
                }
            } catch {
                # Re-throw safety primitive failures (missing timeout helper)
                if ($_.Exception.Message -match 'Invoke-WithTimeout') { throw }
                $findings.Add([PSCustomObject]@{
                    Id          = [guid]::NewGuid().ToString()
                    RuleId      = 'BICEP-VALIDATION-ERROR'
                    Level       = 'Error'
                    Category    = 'IaC Validation'
                    Title       = "Bicep validation error: $relativePath"
                    Severity    = 'Error'
                    Compliant   = $false
                    Detail      = Remove-Credentials ([string]$_)
                    Remediation = "Ensure bicep CLI is available and the file is valid"
                    ResourceId  = $relativePath
                    LearnMoreUrl = 'https://learn.microsoft.com/azure/azure-resource-manager/bicep/overview'
                })
            }
        }
    } finally {
        # Always clean up generated ARM JSON files so the user's repo is not polluted
        foreach ($jsonPath in $generatedJsonFiles) {
            if (Test-Path $jsonPath) {
                Remove-Item $jsonPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    return [PSCustomObject]@{
        Source   = 'bicep-iac'
        SchemaVersion = '1.0'
        Status   = 'Success'
        Message  = ''
        Findings = $findings
    }
}

function Get-TerraformToolVersion {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $Command,
        [string[]] $Arguments = @('--version')
    )

    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) { return '' }
    try {
        Assert-TimeoutHelperLoaded
        $result = Invoke-WithTimeout -Command $Command -Arguments $Arguments -TimeoutSec $script:IaCTimeoutSec
        if ($result.ExitCode -eq 0 -and $result.Output) {
            return (($result.Output -split "`r?`n")[0]).Trim()
        }
    } catch {
        Write-Verbose "Version probe failed for $Command`: $(Remove-Credentials ([string]$_.Exception.Message))"
    }
    return ''
}

function Resolve-TerraformToolLabel {
    param ([string] $RuleId)
    if ([string]::IsNullOrWhiteSpace($RuleId)) { return 'terraform' }
    if ($RuleId -match '^(?i)CKV_') { return 'checkov' }
    if ($RuleId -match '^(?i)TFSEC|^AWS\d+|^AZU\d+') { return 'tfsec' }
    return 'trivy'
}

function Resolve-TerraformRulePillar {
    param (
        [string] $RuleId,
        [string] $Title,
        [string] $Description,
        [string] $Category
    )

    $signal = "$RuleId $Title $Description $Category".ToLowerInvariant()
    if ($signal -match 'cost|price|sku|sizing|idle|rightsiz') { return 'CostOptimization' }
    if ($signal -match 'performance|latency|throughput|iops|autoscal|cache') { return 'PerformanceEfficiency' }
    if ($signal -match 'operations|operational|monitor|logging|diagnostic|tagging|policy') { return 'OperationalExcellence' }
    if ($signal -match 'reliability|availability|redundan|backup|recovery|resilien') { return 'Reliability' }
    return 'Security'
}

function Resolve-TerraformFrameworks {
    param (
        [string] $RuleId,
        [string] $Title,
        [string] $Description
    )

    $frameworks = [System.Collections.Generic.List[hashtable]]::new()
    $signal = "$RuleId $Title $Description".ToLowerInvariant()
    $control = if ([string]::IsNullOrWhiteSpace($RuleId)) { 'terraform-validate' } else { $RuleId.ToUpperInvariant() }

    function Add-Framework {
        param([string] $Kind, [string] $ControlId)
        if ([string]::IsNullOrWhiteSpace($Kind) -or [string]::IsNullOrWhiteSpace($ControlId)) { return }
        foreach ($existing in $frameworks) {
            if ($existing.kind -eq $Kind -and $existing.controlId -eq $ControlId) { return }
        }
        $frameworks.Add(@{ kind = $Kind; controlId = $ControlId }) | Out-Null
    }

    if ($signal -match 'avd-azu-|azure|azurerm|azapi') {
        Add-Framework -Kind 'Azure WAF' -ControlId $control
        Add-Framework -Kind 'CIS Azure' -ControlId $control
        Add-Framework -Kind 'Azure Security Benchmark' -ControlId $control
        Add-Framework -Kind 'NIST 800-53' -ControlId $control
    } else {
        if ($signal -match 'waf|well-architected') { Add-Framework -Kind 'Azure WAF' -ControlId $control }
        if ($signal -match 'cis') { Add-Framework -Kind 'CIS Azure' -ControlId $control }
        if ($signal -match 'asb|azure security benchmark|microsoft cloud security benchmark') { Add-Framework -Kind 'Azure Security Benchmark' -ControlId $control }
        if ($signal -match 'nist') { Add-Framework -Kind 'NIST 800-53' -ControlId $control }
    }

    return @($frameworks)
}

function Resolve-TerraformDeepLinkUrl {
    param (
        [string] $RuleId,
        [string] $PrimaryUrl,
        [string[]] $References
    )

    if (-not [string]::IsNullOrWhiteSpace($PrimaryUrl)) { return $PrimaryUrl.Trim() }
    foreach ($reference in @($References)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$reference)) { return ([string]$reference).Trim() }
    }
    if ([string]::IsNullOrWhiteSpace($RuleId)) { return '' }

    $upperRule = $RuleId.Trim().ToUpperInvariant()
    if ($upperRule -match '^AVD-[A-Z]+-\d+$') {
        return "https://avd.aquasec.com/misconfig/$($upperRule.ToLowerInvariant())"
    }
    if ($upperRule -match '^TFSEC') {
        return "https://aquasecurity.github.io/tfsec/latest/checks/#$($upperRule.ToLowerInvariant())"
    }
    if ($upperRule -match '^CKV_') {
        return "https://www.checkov.io/5.Policy%20Index/all.html#$($upperRule.ToLowerInvariant())"
    }
    return ''
}

function Resolve-TerraformProviderTag {
    param (
        [string] $RuleId,
        [string] $Title,
        [string] $Description
    )

    $signal = "$RuleId $Title $Description".ToLowerInvariant()
    if ($signal -match 'azapi') { return 'azapi' }
    return 'azurerm'
}

function Resolve-TerraformRemediationSnippets {
    param (
        [string] $RuleId,
        [string] $Resolution
    )

    $snippets = [System.Collections.Generic.List[hashtable]]::new()
    $rule = if ($RuleId) { $RuleId.ToUpperInvariant() } else { '' }
    if ($rule -eq 'AVD-AZU-0001') {
        $snippets.Add(@{
                language = 'hcl'
                code     = "- allow_blob_public_access = true`n+ allow_blob_public_access = false"
            }) | Out-Null
    } elseif ($rule -eq 'AVD-AZU-0050') {
        $snippets.Add(@{
                language = 'hcl'
                code     = "- purge_protection_enabled = false`n+ purge_protection_enabled = true"
            }) | Out-Null
    } elseif (-not [string]::IsNullOrWhiteSpace($Resolution)) {
        $snippets.Add(@{
                language = 'hcl'
                code     = "- # insecure configuration`n+ # remediation: $($Resolution.Trim())"
            }) | Out-Null
    }

    return @($snippets)
}

function Resolve-TerraformGitHubBlobBase {
    param ([string] $SourceRepoUrl)
    if ([string]::IsNullOrWhiteSpace($SourceRepoUrl)) { return '' }
    $trimmed = $SourceRepoUrl.Trim()

    if ($trimmed -match '^(?i)https://([^/]+)/([^/]+)/([^/.]+?)(?:\.git)?/?$') {
        return "https://$($Matches[1])/$($Matches[2])/$($Matches[3])/blob/HEAD"
    }
    if ($trimmed -match '^(?i)github\.com/([^/]+)/([^/.]+?)(?:\.git)?/?$') {
        return "https://github.com/$($Matches[1])/$($Matches[2])/blob/HEAD"
    }
    return ''
}

function Resolve-TerraformEvidenceUris {
    param (
        [string] $RepoPath,
        [string] $RelativeDir,
        [string] $TargetPath,
        [int] $Line,
        [string] $SourceRepoUrl
    )

    $target = if ([string]::IsNullOrWhiteSpace($TargetPath)) { 'main.tf' } else { $TargetPath }
    $relativePath = if ([System.IO.Path]::IsPathRooted($target)) {
        if ($target.StartsWith($RepoPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $target.Substring($RepoPath.Length).TrimStart('\', '/')
        } else {
            [System.IO.Path]::GetFileName($target)
        }
    } elseif ($RelativeDir -eq '.' -or [string]::IsNullOrWhiteSpace($RelativeDir)) {
        $target.TrimStart('\', '/')
    } else {
        Join-Path $RelativeDir $target
    }
    $relativePath = $relativePath -replace '\\', '/'

    $lineAnchor = if ($Line -gt 0) { "#L$Line" } else { '' }
    $uris = [System.Collections.Generic.List[string]]::new()
    $blobBase = Resolve-TerraformGitHubBlobBase -SourceRepoUrl $SourceRepoUrl
    if (-not [string]::IsNullOrWhiteSpace($blobBase)) {
        $uris.Add("$blobBase/$relativePath$lineAnchor") | Out-Null
    }
    $uris.Add("file://$relativePath$lineAnchor") | Out-Null
    return @($uris | Select-Object -Unique)
}

function Resolve-TerraformEntityRefs {
    param (
        [string] $RelativePath,
        [string] $ResourceAddress
    )

    $refs = [System.Collections.Generic.List[string]]::new()
    $path = $RelativePath -replace '\\', '/' -replace '^\./', ''
    if (-not [string]::IsNullOrWhiteSpace($path)) {
        $refs.Add("iac:terraform:$path") | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($ResourceAddress)) {
        $refs.Add("iac:terraform:$path#$ResourceAddress") | Out-Null
        if ($ResourceAddress -match '^(module\.[^.]+)') {
            $refs.Add("iac:terraform:$path#$($Matches[1])") | Out-Null
        }
    }
    return @($refs | Select-Object -Unique)
}

function Invoke-TerraformValidation {
    <#
    .SYNOPSIS
        Run terraform validate and trivy config against Terraform directories.
    .DESCRIPTION
        Discovers directories containing .tf files and runs terraform validate
        (syntax-only, no init required for basic validation) plus trivy config
        for security scanning of HCL files.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $RepoPath,
        [string] $SourceRepoUrl = ''
    )

    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()
    $tfFiles = @(Get-ChildItem -Path $RepoPath -Filter '*.tf' -Recurse -File -ErrorAction SilentlyContinue)

    if ($tfFiles.Count -eq 0) {
        return [PSCustomObject]@{
            Source = 'terraform-iac'
            SchemaVersion = '1.0'; Status = 'Success'
            Message = 'No .tf files found'; Findings = @()
        }
    }

    $versions = @{
        terraform = Get-TerraformToolVersion -Command 'terraform' -Arguments @('version')
        trivy     = Get-TerraformToolVersion -Command 'trivy' -Arguments @('--version')
        tfsec     = Get-TerraformToolVersion -Command 'tfsec' -Arguments @('--version')
        checkov   = Get-TerraformToolVersion -Command 'checkov' -Arguments @('--version')
    }

    $summary = [System.Collections.Generic.List[string]]::new()
    foreach ($key in @('terraform', 'trivy', 'tfsec', 'checkov')) {
        if (-not [string]::IsNullOrWhiteSpace([string]$versions[$key])) {
            $summary.Add($versions[$key]) | Out-Null
        }
    }
    $toolVersionSummary = ($summary -join '; ')

    # Get unique directories containing .tf files
    $tfDirs = $tfFiles | ForEach-Object { $_.DirectoryName } | Select-Object -Unique

    foreach ($dir in $tfDirs) {
        $relativeDir = $dir.Substring($RepoPath.Length).TrimStart('\', '/')
        if (-not $relativeDir) { $relativeDir = '.' }

        Invoke-TerraformValidateDir -RepoPath $RepoPath -Dir $dir -RelativeDir $relativeDir -Findings $findings -ToolVersions $versions -ToolVersionSummary $toolVersionSummary -SourceRepoUrl $SourceRepoUrl
        Invoke-TrivyConfigDir -RepoPath $RepoPath -Dir $dir -RelativeDir $relativeDir -Findings $findings -ToolVersions $versions -ToolVersionSummary $toolVersionSummary -SourceRepoUrl $SourceRepoUrl
    }

    return [PSCustomObject]@{
        Source      = 'terraform-iac'
        SchemaVersion = '1.0'
        Status      = 'Success'
        Message     = ''
        ToolVersion = $toolVersionSummary
        Findings    = $findings
    }
}

function Invoke-TerraformValidateDir {
    <#
    .SYNOPSIS
        Run terraform validate against a single directory.
    .DESCRIPTION
        Uses Invoke-WithTimeout (300s) for the external process call.
        Exit code is captured via the timeout helper's return object,
        avoiding script-scope variable races under WorkerPool concurrency.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $RepoPath,

        [Parameter(Mandatory)]
        [string] $Dir,

        [Parameter(Mandatory)]
        [string] $RelativeDir,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[PSCustomObject]] $Findings,

        [hashtable] $ToolVersions = @{},
        [string] $ToolVersionSummary = '',
        [string] $SourceRepoUrl = ''
    )

    if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
        return
    }

    try {
        Assert-TimeoutHelperLoaded

        # terraform validate requires init on fresh clones; run init -backend=false
        # to download provider schemas without configuring remote state
        $initResult = Invoke-WithTimeout -Command 'terraform' -Arguments @('-chdir', $Dir, 'init', '-backend=false', '-input=false') -TimeoutSec $script:IaCTimeoutSec
        if ($initResult.ExitCode -ne 0) {
            $evidenceUris = Resolve-TerraformEvidenceUris -RepoPath $RepoPath -RelativeDir $RelativeDir -TargetPath 'main.tf' -Line 0 -SourceRepoUrl $SourceRepoUrl
            # init failed; emit a finding and skip validate for this directory
            $Findings.Add([PSCustomObject]@{
                Id          = [guid]::NewGuid().ToString()
                Category    = 'IaC Validation'
                Title       = "Terraform init required: $RelativeDir"
                RuleId      = 'terraform-init'
                Severity    = 'Medium'
                Compliant   = $false
                Detail      = Remove-Credentials "terraform init -backend=false failed. Provider plugins may be unavailable. Output: $($initResult.Output.Substring(0, [Math]::Min($initResult.Output.Length, 500)))"
                Remediation = "Run 'terraform init' in $RelativeDir before validation, or ensure provider plugins are accessible."
                ResourceId  = $RelativeDir
                LearnMoreUrl = 'https://developer.hashicorp.com/terraform/cli/commands/init'
                Pillar      = 'OperationalExcellence'
                Frameworks  = @()
                DeepLinkUrl = 'https://developer.hashicorp.com/terraform/cli/commands/init'
                RemediationSnippets = @(@{
                            language = 'hcl'
                            code     = "- # provider not initialized`n+ terraform init -backend=false"
                        })
                EvidenceUris = $evidenceUris
                BaselineTags = @('terraform:rule:terraform-init','terraform:provider:azurerm','terraform:tool:terraform')
                EntityRefs   = Resolve-TerraformEntityRefs -RelativePath (Join-Path $RelativeDir 'main.tf') -ResourceAddress ''
                ToolVersion  = if ($ToolVersions.terraform) { [string]$ToolVersions.terraform } else { $ToolVersionSummary }
            })
            return
        }

        $result = Invoke-WithTimeout -Command 'terraform' -Arguments @('-chdir', $Dir, 'validate', '-json') -TimeoutSec $script:IaCTimeoutSec
        $exitCode = $result.ExitCode
        $jsonText = $result.Output

        if ($exitCode -ne 0 -and $jsonText) {
            try {
                $parsed = $jsonText | ConvertFrom-Json -ErrorAction Stop
                if ($parsed.PSObject.Properties['diagnostics'] -and $parsed.diagnostics) {
                    foreach ($diag in $parsed.diagnostics) {
                        $severity = switch ($diag.severity) {
                            'error'   { 'High' }
                            'warning' { 'Medium' }
                            default   { 'Medium' }
                        }
                        $detail = if ($diag.PSObject.Properties['detail'] -and $diag.detail) { $diag.detail } else { $diag.summary }
                        $line = 0
                        $targetPath = 'main.tf'
                        if ($diag.PSObject.Properties['range'] -and $diag.range) {
                            if ($diag.range.PSObject.Properties['start'] -and $diag.range.start -and $diag.range.start.PSObject.Properties['line']) {
                                $line = [int]$diag.range.start.line
                            }
                            if ($diag.range.PSObject.Properties['filename'] -and $diag.range.filename) {
                                $targetPath = [string]$diag.range.filename
                            }
                        }
                        $evidenceUris = Resolve-TerraformEvidenceUris -RepoPath $RepoPath -RelativeDir $RelativeDir -TargetPath $targetPath -Line $line -SourceRepoUrl $SourceRepoUrl
                        $relativePath = ($evidenceUris[0] -replace '^file://', '') -replace '#L\d+$', ''
                        $Findings.Add([PSCustomObject]@{
                            Id          = [guid]::NewGuid().ToString()
                            Category    = 'IaC Validation'
                            Title       = "Terraform validate: $($diag.summary)"
                            RuleId      = 'terraform-validate'
                            Severity    = $severity
                            Compliant   = $false
                            Detail      = Remove-Credentials $detail
                            Remediation = "Fix the Terraform configuration in $RelativeDir"
                            ResourceId  = $RelativeDir
                            LearnMoreUrl = 'https://developer.hashicorp.com/terraform/cli/commands/validate'
                            Pillar      = 'OperationalExcellence'
                            Frameworks  = @()
                            DeepLinkUrl = 'https://developer.hashicorp.com/terraform/cli/commands/validate'
                            RemediationSnippets = @(@{
                                        language = 'hcl'
                                        code     = "- # failing expression`n+ # update expression to satisfy terraform validate"
                                    })
                            EvidenceUris = $evidenceUris
                            BaselineTags = @('terraform:rule:terraform-validate','terraform:provider:azurerm','terraform:tool:terraform')
                            EntityRefs   = Resolve-TerraformEntityRefs -RelativePath $relativePath -ResourceAddress ''
                            ToolVersion  = if ($ToolVersions.terraform) { [string]$ToolVersions.terraform } else { $ToolVersionSummary }
                        })
                    }
                }
            } catch {
                $evidenceUris = Resolve-TerraformEvidenceUris -RepoPath $RepoPath -RelativeDir $RelativeDir -TargetPath 'main.tf' -Line 0 -SourceRepoUrl $SourceRepoUrl
                $Findings.Add([PSCustomObject]@{
                    Id          = [guid]::NewGuid().ToString()
                    Category    = 'IaC Validation'
                    Title       = "Terraform validate failed: $RelativeDir"
                    RuleId      = 'terraform-validate'
                    Severity    = 'High'
                    Compliant   = $false
                    Detail      = Remove-Credentials ($jsonText.Substring(0, [Math]::Min($jsonText.Length, 500)))
                    Remediation = "Fix the Terraform configuration in $RelativeDir"
                    ResourceId  = $RelativeDir
                    LearnMoreUrl = 'https://developer.hashicorp.com/terraform/cli/commands/validate'
                    Pillar      = 'OperationalExcellence'
                    Frameworks  = @()
                    DeepLinkUrl = 'https://developer.hashicorp.com/terraform/cli/commands/validate'
                    RemediationSnippets = @(@{
                                language = 'hcl'
                                code     = "- # invalid terraform configuration`n+ # fix diagnostics and re-run terraform validate"
                            })
                    EvidenceUris = $evidenceUris
                    BaselineTags = @('terraform:rule:terraform-validate','terraform:provider:azurerm','terraform:tool:terraform')
                    EntityRefs   = Resolve-TerraformEntityRefs -RelativePath (Join-Path $RelativeDir 'main.tf') -ResourceAddress ''
                    ToolVersion  = if ($ToolVersions.terraform) { [string]$ToolVersions.terraform } else { $ToolVersionSummary }
                })
            }
        }
    } catch {
        # Re-throw safety primitive failures (missing timeout helper)
        if ($_.Exception.Message -match 'Invoke-WithTimeout') { throw }
        Write-Verbose "terraform validate failed in $Dir`: $(Remove-Credentials ([string]$_))"
    }
}

function Invoke-TrivyConfigDir {
    <#
    .SYNOPSIS
        Run trivy config against a directory for HCL/Terraform security findings.
    .DESCRIPTION
        Uses trivy config (which subsumes tfsec) for IaC security scanning.
        External process is wrapped in Invoke-WithTimeout (300s hard cap).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $RepoPath,

        [Parameter(Mandatory)]
        [string] $Dir,

        [Parameter(Mandatory)]
        [string] $RelativeDir,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[PSCustomObject]] $Findings,

        [hashtable] $ToolVersions = @{},
        [string] $ToolVersionSummary = '',
        [string] $SourceRepoUrl = ''
    )

    if (-not (Get-Command trivy -ErrorAction SilentlyContinue)) {
        return
    }

    $reportFile = Join-Path ([System.IO.Path]::GetTempPath()) "trivy-config-$([guid]::NewGuid().ToString('N')).json"
    try {
        Assert-TimeoutHelperLoaded
        $result = Invoke-WithTimeout -Command 'trivy' -Arguments @('config', '--format', 'json', '--output', $reportFile, $Dir) -TimeoutSec $script:IaCTimeoutSec
        if ($result.ExitCode -eq -1) {
            $evidenceUris = Resolve-TerraformEvidenceUris -RepoPath $RepoPath -RelativeDir $RelativeDir -TargetPath 'main.tf' -Line 0 -SourceRepoUrl $SourceRepoUrl
            $Findings.Add([PSCustomObject]@{
                Id          = [guid]::NewGuid().ToString()
                Category    = 'IaC Security'
                Title       = "Trivy scan incomplete: timed out after $($script:IaCTimeoutSec)s"
                RuleId      = 'trivy-timeout'
                Severity    = 'High'
                Compliant   = $false
                Detail      = Remove-Credentials "trivy config timed out after $($script:IaCTimeoutSec) seconds scanning $RelativeDir. Security findings may be missing."
                Remediation = "Reduce the scan scope or increase the timeout budget. Consider scanning subdirectories individually."
                ResourceId  = $RelativeDir
                LearnMoreUrl = 'https://github.com/aquasecurity/trivy'
                Pillar      = 'Security'
                Frameworks  = @()
                DeepLinkUrl = 'https://github.com/aquasecurity/trivy'
                RemediationSnippets = @(@{
                            language = 'hcl'
                            code     = "- # scan scope too broad`n+ # split Terraform modules into smaller directories"
                        })
                EvidenceUris = $evidenceUris
                BaselineTags = @('terraform:rule:trivy-timeout','terraform:provider:azurerm','terraform:tool:trivy')
                EntityRefs   = Resolve-TerraformEntityRefs -RelativePath (Join-Path $RelativeDir 'main.tf') -ResourceAddress ''
                ToolVersion  = if ($ToolVersions.trivy) { [string]$ToolVersions.trivy } else { $ToolVersionSummary }
            })
            return
        }

        if (Test-Path $reportFile) {
            $jsonText = Get-Content $reportFile -Raw -ErrorAction SilentlyContinue
            if ($jsonText) {
                try {
                    $json = $jsonText | ConvertFrom-Json -ErrorAction Stop
                } catch {
                    Write-Verbose "trivy config JSON parse failed: $(Remove-Credentials ([string]$_))"
                    return
                }

                $results = $null
                if ($null -ne $json -and $json.PSObject.Properties['Results'] -and $json.Results) {
                    $results = $json.Results
                }

                if ($results) {
                    foreach ($result in $results) {
                        $misconfigs = $null
                        if ($result.PSObject.Properties['Misconfigurations'] -and $result.Misconfigurations) {
                            $misconfigs = $result.Misconfigurations
                        }
                        if (-not $misconfigs) { continue }

                        foreach ($mc in $misconfigs) {
                            $mcId = if ($mc.PSObject.Properties['ID'] -and $mc.ID) { $mc.ID } else { '' }
                            $mcTitle = if ($mc.PSObject.Properties['Title'] -and $mc.Title) { $mc.Title } else { '' }
                            $mcDesc = if ($mc.PSObject.Properties['Description'] -and $mc.Description) { $mc.Description } else { '' }
                            $mcRes = if ($mc.PSObject.Properties['Resolution'] -and $mc.Resolution) { $mc.Resolution } else { '' }
                            $mcSev = if ($mc.PSObject.Properties['Severity'] -and $mc.Severity) { $mc.Severity } else { 'MEDIUM' }
                            $mcPrimary = if ($mc.PSObject.Properties['PrimaryURL'] -and $mc.PrimaryURL) { [string]$mc.PrimaryURL } else { '' }
                            $mcReferences = if ($mc.PSObject.Properties['References'] -and $mc.References) { @($mc.References) } else { @() }
                            $mcUrl = ''
                            if (-not [string]::IsNullOrWhiteSpace($mcPrimary)) {
                                $mcUrl = $mcPrimary
                            } elseif ($mcReferences.Count -gt 0) {
                                $mcUrl = [string]$mcReferences[0]
                            }

                            $severity = switch -Regex ($mcSev.ToString().ToLowerInvariant()) {
                                'CRITICAL' { 'Critical' }
                                'HIGH'     { 'High' }
                                'MEDIUM'   { 'Medium' }
                                'LOW'      { 'Low' }
                                'UNKNOWN'  { 'Info' }
                                default    { 'Info' }
                            }

                            $title = if ($mcId -and $mcTitle) { "$mcId`: $mcTitle" }
                                     elseif ($mcId) { $mcId }
                                     elseif ($mcTitle) { $mcTitle }
                                     else { 'Unknown misconfiguration' }
                            $targetPath = if ($result.PSObject.Properties['Target'] -and $result.Target) { [string]$result.Target } else { 'main.tf' }
                            $resourceAddress = ''
                            if ($mc.PSObject.Properties['CauseMetadata'] -and $mc.CauseMetadata -and $mc.CauseMetadata.PSObject.Properties['Resource'] -and $mc.CauseMetadata.Resource) {
                                $resourceAddress = [string]$mc.CauseMetadata.Resource
                            } elseif ($mc.PSObject.Properties['Query'] -and $mc.Query) {
                                $resourceAddress = [string]$mc.Query
                            }
                            $startLine = 0
                            if ($mc.PSObject.Properties['CauseMetadata'] -and $mc.CauseMetadata -and $mc.CauseMetadata.PSObject.Properties['StartLine'] -and $mc.CauseMetadata.StartLine) {
                                $startLine = [int]$mc.CauseMetadata.StartLine
                            }
                            $evidenceUris = Resolve-TerraformEvidenceUris -RepoPath $RepoPath -RelativeDir $RelativeDir -TargetPath $targetPath -Line $startLine -SourceRepoUrl $SourceRepoUrl
                            $relativePath = ($evidenceUris[0] -replace '^file://', '') -replace '#L\d+$', ''
                            $providerTag = Resolve-TerraformProviderTag -RuleId $mcId -Title $mcTitle -Description $mcDesc
                            $toolLabel = Resolve-TerraformToolLabel -RuleId $mcId
                            $ruleId = if ($mcId) { [string]$mcId } else { 'terraform-misconfiguration' }
                            $deepLinkUrl = Resolve-TerraformDeepLinkUrl -RuleId $ruleId -PrimaryUrl $mcPrimary -References $mcReferences
                            $frameworks = Resolve-TerraformFrameworks -RuleId $ruleId -Title $mcTitle -Description $mcDesc
                            $pillar = Resolve-TerraformRulePillar -RuleId $ruleId -Title $mcTitle -Description $mcDesc -Category 'IaC Security'
                            $remediationSnippets = Resolve-TerraformRemediationSnippets -RuleId $ruleId -Resolution $mcRes
                            $entityRefs = Resolve-TerraformEntityRefs -RelativePath $relativePath -ResourceAddress $resourceAddress
                            $toolVersion = ''
                            if ($ToolVersions.ContainsKey($toolLabel) -and $ToolVersions[$toolLabel]) {
                                $toolVersion = [string]$ToolVersions[$toolLabel]
                            } elseif ($ToolVersions.trivy) {
                                $toolVersion = [string]$ToolVersions.trivy
                            } else {
                                $toolVersion = $ToolVersionSummary
                            }

                            $Findings.Add([PSCustomObject]@{
                                Id          = [guid]::NewGuid().ToString()
                                Category    = 'IaC Security'
                                Title       = $title
                                RuleId      = $ruleId
                                Severity    = $severity
                                Compliant   = $false
                                Detail      = Remove-Credentials $mcDesc
                                Remediation = $mcRes
                                ResourceId  = $RelativeDir
                                LearnMoreUrl = $mcUrl
                                Pillar      = $pillar
                                Frameworks  = $frameworks
                                DeepLinkUrl = $deepLinkUrl
                                RemediationSnippets = $remediationSnippets
                                EvidenceUris = $evidenceUris
                                BaselineTags = @("terraform:rule:$($ruleId.ToLowerInvariant())","terraform:provider:$providerTag","terraform:tool:$toolLabel")
                                EntityRefs   = $entityRefs
                                ResourceAddress = $resourceAddress
                                ToolVersion = $toolVersion
                            })
                        }
                    }
                }
            }
        }
    } finally {
        Remove-Item $reportFile -Force -ErrorAction SilentlyContinue
    }
}
