#Requires -Version 7.4
<#
.SYNOPSIS
    Shared adapter loader for IaC validation tools.
.DESCRIPTION
    Exports Invoke-IaCAdapter which dispatches to flavour-specific validation
    helpers (bicep, terraform). Each adapter returns a v1 wrapper envelope
    (SchemaVersion 1.0, Status, Findings[]) consistent with other wrappers.

    All external process launches go through Invoke-WithTimeout (300s hard cap)
    and Invoke-WithRetry (transient-error resilience).
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

        [string] $RemoteUrl
    )

    $cloneInfo = $null
    $cleanupClone = $null
    try {
        if ($RemoteUrl) {
            if (-not (Get-Command Invoke-RemoteRepoClone -ErrorAction SilentlyContinue)) {
                Write-Warning "RemoteClone helper not loaded; cannot scan remote URL."
                return [PSCustomObject]@{
                    Source = "iac-$Flavour"; Status = 'Failed'
                    Message = 'RemoteClone helper unavailable'; Findings = @()
                }
            }
            $cloneInfo = Invoke-RemoteRepoClone -RepoUrl $RemoteUrl
            if (-not $cloneInfo) {
                return [PSCustomObject]@{
                    Source = "iac-$Flavour"; Status = 'Failed'
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
                Message = 'No -RepoPath or -RemoteUrl provided'; Findings = @()
            }
        }

        switch ($Flavour) {
            'bicep' { return Invoke-BicepValidation -RepoPath $RepoPath }
            'terraform' { return Invoke-TerraformValidation -RepoPath $RepoPath }
            default {
                return [PSCustomObject]@{
                    Source = "iac-$Flavour"; Status = 'Skipped'
                    Message = "Unsupported IaC flavour: $Flavour"; Findings = @()
                }
            }
        }
    } catch {
        Write-Warning (Remove-Credentials "IaC adapter ($Flavour) failed: $_")
        return [PSCustomObject]@{
            Source = "iac-$Flavour"; Status = 'Failed'
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

    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()
    $bicepFiles = Get-ChildItem -Path $RepoPath -Filter '*.bicep' -Recurse -File -ErrorAction SilentlyContinue

    if (-not $bicepFiles -or $bicepFiles.Count -eq 0) {
        return [PSCustomObject]@{
            Source = 'bicep-iac'; Status = 'Success'
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
                        $severity = if ($lineStr -match '\bError\b') { 'High' }
                                    elseif ($lineStr -match '\bWarning\b') { 'Medium' }
                                    else { 'Medium' }

                        $findings.Add([PSCustomObject]@{
                            Id          = [guid]::NewGuid().ToString()
                            Category    = 'IaC Validation'
                            Title       = "Bicep build error: $relativePath"
                            Severity    = $severity
                            Compliant   = $false
                            Detail      = $lineStr
                            Remediation = "Fix the Bicep syntax or reference error in $relativePath"
                            ResourceId  = $relativePath
                            LearnMoreUrl = 'https://learn.microsoft.com/azure/azure-resource-manager/bicep/overview'
                        })
                    }

                    if ($errorLines.Count -eq 0) {
                        $findings.Add([PSCustomObject]@{
                            Id          = [guid]::NewGuid().ToString()
                            Category    = 'IaC Validation'
                            Title       = "Bicep build failed: $relativePath"
                            Severity    = 'High'
                            Compliant   = $false
                            Detail      = Remove-Credentials $outputText
                            Remediation = "Fix the Bicep file at $relativePath"
                            ResourceId  = $relativePath
                            LearnMoreUrl = 'https://learn.microsoft.com/azure/azure-resource-manager/bicep/overview'
                        })
                    }
                }
            } catch {
                $findings.Add([PSCustomObject]@{
                    Id          = [guid]::NewGuid().ToString()
                    Category    = 'IaC Validation'
                    Title       = "Bicep validation error: $relativePath"
                    Severity    = 'High'
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
        Status   = 'Success'
        Message  = ''
        Findings = $findings
    }
}

function Invoke-TerraformValidation {
    <#
    .SYNOPSIS
        Run terraform validate and trivy config against Terraform directories.
    .DESCRIPTION
        Discovers directories containing .tf files and runs terraform validate
        (syntax-only, no init required for basic validation) plus trivy config
        for security scanning of HCL files.

        Design choice: uses trivy config instead of standalone tfsec because
        Aqua merged tfsec into trivy. Since trivy is already in our manifest,
        this avoids adding another external dependency.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $RepoPath
    )

    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()
    $tfFiles = Get-ChildItem -Path $RepoPath -Filter '*.tf' -Recurse -File -ErrorAction SilentlyContinue

    if (-not $tfFiles -or $tfFiles.Count -eq 0) {
        return [PSCustomObject]@{
            Source = 'terraform-iac'; Status = 'Success'
            Message = 'No .tf files found'; Findings = @()
        }
    }

    # Get unique directories containing .tf files
    $tfDirs = $tfFiles | ForEach-Object { $_.DirectoryName } | Select-Object -Unique

    foreach ($dir in $tfDirs) {
        $relativeDir = $dir.Substring($RepoPath.Length).TrimStart('\', '/')
        if (-not $relativeDir) { $relativeDir = '.' }

        # Run terraform validate (syntax-only mode)
        Invoke-TerraformValidateDir -Dir $dir -RelativeDir $relativeDir -Findings $findings

        # Run trivy config for HCL security scanning (preferred over tfsec)
        Invoke-TrivyConfigDir -Dir $dir -RelativeDir $relativeDir -Findings $findings
    }

    return [PSCustomObject]@{
        Source   = 'terraform-iac'
        Status   = 'Success'
        Message  = ''
        Findings = $findings
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
        [string] $Dir,

        [Parameter(Mandatory)]
        [string] $RelativeDir,

        [Parameter(Mandatory)]
        [System.Collections.Generic.List[PSCustomObject]] $Findings
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
            # init failed; emit a finding and skip validate for this directory
            $Findings.Add([PSCustomObject]@{
                Id          = [guid]::NewGuid().ToString()
                Category    = 'IaC Validation'
                Title       = "Terraform init required: $RelativeDir"
                Severity    = 'Medium'
                Compliant   = $false
                Detail      = Remove-Credentials "terraform init -backend=false failed. Provider plugins may be unavailable. Output: $($initResult.Output.Substring(0, [Math]::Min($initResult.Output.Length, 500)))"
                Remediation = "Run 'terraform init' in $RelativeDir before validation, or ensure provider plugins are accessible."
                ResourceId  = $RelativeDir
                LearnMoreUrl = 'https://developer.hashicorp.com/terraform/cli/commands/init'
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
                        $Findings.Add([PSCustomObject]@{
                            Id          = [guid]::NewGuid().ToString()
                            Category    = 'IaC Validation'
                            Title       = "Terraform validate: $($diag.summary)"
                            Severity    = $severity
                            Compliant   = $false
                            Detail      = Remove-Credentials $detail
                            Remediation = "Fix the Terraform configuration in $RelativeDir"
                            ResourceId  = $RelativeDir
                            LearnMoreUrl = 'https://developer.hashicorp.com/terraform/cli/commands/validate'
                        })
                    }
                }
            } catch {
                $Findings.Add([PSCustomObject]@{
                    Id          = [guid]::NewGuid().ToString()
                    Category    = 'IaC Validation'
                    Title       = "Terraform validate failed: $RelativeDir"
                    Severity    = 'High'
                    Compliant   = $false
                    Detail      = Remove-Credentials ($jsonText.Substring(0, [Math]::Min($jsonText.Length, 500)))
                    Remediation = "Fix the Terraform configuration in $RelativeDir"
                    ResourceId  = $RelativeDir
                    LearnMoreUrl = 'https://developer.hashicorp.com/terraform/cli/commands/validate'
                })
            }
        }
    } catch {
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
        [string] $Dir,

        [Parameter(Mandatory)]
        [string] $RelativeDir,

        [Parameter(Mandatory)]
        [System.Collections.Generic.List[PSCustomObject]] $Findings
    )

    if (-not (Get-Command trivy -ErrorAction SilentlyContinue)) {
        return
    }

    $reportFile = Join-Path ([System.IO.Path]::GetTempPath()) "trivy-config-$([guid]::NewGuid().ToString('N')).json"
    try {
        Assert-TimeoutHelperLoaded
        $result = Invoke-WithTimeout -Command 'trivy' -Arguments @('config', '--format', 'json', '--output', $reportFile, $Dir) -TimeoutSec $script:IaCTimeoutSec
        if ($result.ExitCode -eq -1) {
            Write-Verbose "trivy config timed out for $Dir"
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
                            $mcUrl = ''
                            if ($mc.PSObject.Properties['PrimaryURL'] -and $mc.PrimaryURL) {
                                $mcUrl = $mc.PrimaryURL
                            } elseif ($mc.PSObject.Properties['References'] -and $mc.References -and $mc.References.Count -gt 0) {
                                $mcUrl = $mc.References[0]
                            }

                            $severity = switch ($mcSev.ToUpperInvariant()) {
                                'CRITICAL' { 'Critical' }
                                'HIGH'     { 'High' }
                                'MEDIUM'   { 'Medium' }
                                'LOW'      { 'Low' }
                                default    { 'Info' }
                            }

                            $title = if ($mcId -and $mcTitle) { "$mcId`: $mcTitle" }
                                     elseif ($mcId) { $mcId }
                                     elseif ($mcTitle) { $mcTitle }
                                     else { 'Unknown misconfiguration' }

                            $Findings.Add([PSCustomObject]@{
                                Id          = [guid]::NewGuid().ToString()
                                Category    = 'IaC Security'
                                Title       = $title
                                Severity    = $severity
                                Compliant   = $false
                                Detail      = Remove-Credentials $mcDesc
                                Remediation = $mcRes
                                ResourceId  = $RelativeDir
                                LearnMoreUrl = $mcUrl
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
