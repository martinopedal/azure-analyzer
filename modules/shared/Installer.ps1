#Requires -Version 7.4
<#
.SYNOPSIS
    Manifest-driven prerequisite installer for azure-analyzer.
.DESCRIPTION
    Reads the `install` section of each tool in tools/tool-manifest.json and
    auto-installs missing PowerShell modules, CLI binaries, and git-cloned
    tools (e.g. AzGovViz).

    Install kinds supported:
      - psmodule : Install-Module (PowerShell Gallery).
      - cli      : winget (Windows), brew (macOS), pipx/pip (any), or a
                   URL hint shown to the user.
      - gitclone : git clone --depth 1 into a target directory under the
                   repo root.
      - none     : nothing to install (e.g. ado-connections uses REST only).

    Security hardening:
      - Package names are validated against a conservative regex before
        being handed to a package manager. Anything with shell metachars
        is refused.
      - Git clone URLs must be HTTPS and from an allow-listed host
        (github.com by default).
      - Every install call runs with a timeout (default 300s) so a hung
        mirror can never block the orchestrator indefinitely.
      - Stdout and stderr from package managers are scrubbed via
        Remove-Credentials before being surfaced to the user.
      - Install kinds outside {none, psmodule, cli, gitclone} are refused.

    Behaviour:
      - Only installs tools the user has NOT excluded via -ExcludeTools and
        has enabled via -IncludeTools (if specified).
      - Always idempotent: skips any tool whose probe command / module /
        file already resolves.
      - Never throws -- emits warnings and returns the number of remaining
        unmet prerequisites so the caller can decide how to proceed.
#>
[CmdletBinding()]
param ()

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Security policy
# ---------------------------------------------------------------------------
$script:AllowedInstallKinds   = @('none', 'psmodule', 'cli', 'gitclone')
$script:AllowedPackageManagers = @('winget', 'brew', 'pipx', 'pip', 'snap')
$script:AllowedGitHosts       = @('github.com')
# Package names: letters, digits, dots, dashes, underscores, slashes, at-signs.
# Covers winget IDs (Publisher.Package), brew taps (org/tap/pkg), pipx, pip.
$script:PackageNamePattern    = '^[A-Za-z0-9][A-Za-z0-9._\-/@]{0,127}$'
$script:DefaultInstallTimeoutSec = 300
# Install manifest for version pinning + SHA-256 verification
$script:InstallManifestPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'tools' 'install-manifest.json')
# Default path for optional install configuration
$script:DefaultInstallConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'tools' 'install-config.json')

# Lightweight credential scrubber used when Remove-Credentials isn't in scope.
if (-not (Get-Command -Name Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials {
        param ([string] $Text)
        if ([string]::IsNullOrEmpty($Text)) { return $Text }
        # Strip common token patterns: GitHub, bearer, basic, Azure keys.
        $scrubbed = $Text
        $scrubbed = $scrubbed -replace '(gh[pousr]_[A-Za-z0-9]{36,255})', '[redacted-gh-token]'
        $scrubbed = $scrubbed -replace '(?i)(authorization[:= ]+bearer\s+)[A-Za-z0-9\._\-]+', '$1[redacted]'
        $scrubbed = $scrubbed -replace '(?i)(password[:= ]+)[^\s,;]+', '$1[redacted]'
        return $scrubbed
    }
}

function Get-CurrentOS {
    if ($IsWindows -or ($PSVersionTable.Platform -eq 'Win32NT')) { return 'windows' }
    if ($IsMacOS) { return 'macos' }
    return 'linux'
}

function Test-CliAvailable {
    param ([Parameter(Mandatory)][string] $Command)
    return [bool](Get-Command $Command -ErrorAction SilentlyContinue)
}

function Test-PSModuleAvailable {
    param ([Parameter(Mandatory)][string] $Name)
    return [bool](Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue)
}

function New-InstallerError {
    <#
    .SYNOPSIS
        Build a rich, sanitized error object describing an install failure.
    #>
    param (
        [Parameter(Mandatory)][string] $Tool,
        [Parameter(Mandatory)][ValidateSet('psmodule','cli','gitclone','none')][string] $Kind,
        [Parameter(Mandatory)][string] $Reason,
        [string] $Package,
        [string] $Url,
        [string] $Remediation,
        [string] $Output,
        [string] $Category = 'InstallFailed'
    )
    return [PSCustomObject]@{
        Tool         = $Tool
        Kind         = $Kind
        OS           = Get-CurrentOS
        Package      = $Package
        Url          = $Url
        Category     = $Category
        Reason       = $Reason
        Remediation  = $Remediation
        Output       = Remove-Credentials ([string]$Output)
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Write-InstallerError {
    param ([Parameter(Mandatory)] $Err)
    $line = "[installer] {0} ({1}/{2}): {3}" -f $Err.Tool, $Err.Kind, $Err.Category, $Err.Reason
    if ($Err.Remediation) { $line += " Action: $($Err.Remediation)" }
    Write-Warning $line
    if ($Err.Output) { Write-Verbose $Err.Output }
}

function Invoke-WithInstallRetry {
    <#
    .SYNOPSIS
        Retry a transient install-related scriptblock with jittered
        exponential backoff. Permanent failures (auth, not-found,
        conflict) are surfaced immediately without retry.
    #>
    param (
        [Parameter(Mandatory)][scriptblock] $ScriptBlock,
        [int] $MaxRetries = 2,
        [int] $BaseDelaySec = 2,
        [int] $MaxDelaySec = 20,
        [string[]] $TransientMarkers = @(
            'timed out', 'timeout', 'temporary failure', 'connection reset',
            'could not resolve host', 'network is unreachable',
            'service unavailable', '503', '429', 'rate limit',
            'read timed out', 'tls handshake'
        )
    )
    for ($i = 0; $i -le $MaxRetries; $i++) {
        $result = & $ScriptBlock
        if ($null -eq $result) { return $null }
        if ($result.ExitCode -eq 0) { return $result }
        $lower = ([string]$result.Output).ToLowerInvariant()
        $transient = $false
        foreach ($m in $TransientMarkers) { if ($lower -like "*$m*") { $transient = $true; break } }
        if (-not $transient -or $i -eq $MaxRetries) {
            $result | Add-Member -NotePropertyName Attempts  -NotePropertyValue ($i + 1)      -Force
            $result | Add-Member -NotePropertyName Exhausted -NotePropertyValue ($i -eq $MaxRetries -and $transient) -Force
            return $result
        }
        $delay = Get-JitteredDelay -RetryIndex $i -BaseDelaySec $BaseDelaySec -MaxDelaySec $MaxDelaySec
        Write-Verbose "[installer] transient failure (exit=$($result.ExitCode)); retrying in ${delay}s (attempt $($i + 2)/$($MaxRetries + 1))"
        if ($delay -gt 0) { Start-Sleep -Seconds $delay }
    }
}

function Test-SafePackageName {
    <#
    .SYNOPSIS
        Guard against shell injection via manifest-supplied package names.
    #>
    param ([Parameter(Mandatory)][string] $Name)
    return ($Name -match $script:PackageNamePattern)
}

function Get-FileHash256 {
    <#
    .SYNOPSIS
        Compute SHA-256 hash of a file and return lowercase hex string.
    #>
    param ([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path $Path)) {
        throw "File not found for hash computation: $Path"
    }
    $hash = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
    return $hash.ToLowerInvariant()
}

function Test-InstallManifestHash {
    <#
    .SYNOPSIS
        Verify a downloaded file's SHA-256 against install-manifest.json.
        Returns $true if hash matches, $false if mismatch or no hash in manifest.
    #>
    param (
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][string] $ToolName,
        [string] $Platform = (Get-CurrentOS)
    )
    
    if (-not (Test-Path $script:InstallManifestPath)) {
        Write-Verbose "[hash] install-manifest.json not found; skipping verification for $ToolName"
        return $true
    }
    
    try {
        $manifest = Get-Content $script:InstallManifestPath -Raw | ConvertFrom-Json
        $tool = $manifest.tools | Where-Object { $_.name -eq $ToolName } | Select-Object -First 1
        
        if (-not $tool) {
            Write-Verbose "[hash] $ToolName not found in install manifest; skipping hash check"
            return $true
        }
        
        if (-not $tool.platforms -or -not $tool.platforms.PSObject.Properties[$Platform]) {
            Write-Verbose "[hash] No $Platform entry for $ToolName; skipping hash check"
            return $true
        }
        
        $platformData = $tool.platforms.$Platform
        
        # Check if sha256 property exists
        if (-not $platformData.PSObject.Properties['sha256']) {
            Write-Verbose "[hash] No sha256 property for $ToolName on $Platform; delegating to package manager"
            return $true
        }
        
        if (-not $platformData.sha256 -or $platformData.sha256 -like '*PLACEHOLDER*') {
            Write-Verbose "[hash] No SHA-256 pin for $ToolName on $Platform; delegating to package manager"
            return $true
        }
        
        $expectedHash = $platformData.sha256.ToLowerInvariant()
        $actualHash = Get-FileHash256 -Path $FilePath
        
        if ($actualHash -eq $expectedHash) {
            Write-Verbose "[hash] ✓ $ToolName SHA-256 verified: $actualHash"
            return $true
        } else {
            Write-Warning "[hash] ✗ $ToolName SHA-256 MISMATCH!"
            Write-Warning "       Expected: $expectedHash"
            Write-Warning "       Actual:   $actualHash"
            Write-Warning "       File:     $FilePath"
            return $false
        }
    } catch {
        Write-Warning "[hash] Could not verify $ToolName hash: $($_.Exception.Message)"
        return $false
    }
}

function Test-SafeGitUrl {
    <#
    .SYNOPSIS
        Enforce HTTPS + allow-listed host for auto-cloned tools.
    #>
    param ([Parameter(Mandatory)][string] $Url)
    if ($Url -notmatch '^https://') { return $false }
    $hostPart = ($Url -replace '^https://', '').Split('/')[0].ToLowerInvariant()
    return ($script:AllowedGitHosts -contains $hostPart)
}

function Invoke-WithTimeout {
    <#
    .SYNOPSIS
        Run an external command with stdout+stderr capture and a hard
        timeout. Returns [PSCustomObject]@{ ExitCode; Output }.
    #>
    param (
        [Parameter(Mandatory)][string]   $Command,
        [Parameter(Mandatory)][string[]] $Arguments,
        [int] $TimeoutSec = $script:DefaultInstallTimeoutSec
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Command
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute = $false

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    $null = $proc.Start()

    # Drain streams asynchronously so a full pipe buffer can't deadlock us.
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try { $proc.Kill($true) } catch {
            Write-Verbose ("Invoke-WithTimeout: Process.Kill after timeout failed (process likely already exited). Reason: {0}" -f $_.Exception.Message)
        }
        return [PSCustomObject]@{ ExitCode = -1; Output = "Timed out after $TimeoutSec seconds" }
    }

    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $combined = Remove-Credentials (($stdout + "`n" + $stderr).Trim())
    return [PSCustomObject]@{ ExitCode = $proc.ExitCode; Output = $combined }
}

function Install-PSModules {
    param ([string[]] $Names, [string] $ToolName)
    foreach ($mod in $Names) {
        if (-not (Test-SafePackageName -Name $mod)) {
            Write-Warning "Refusing to install PowerShell module with unsafe name '$mod' for $ToolName."
            continue
        }
        if (Test-PSModuleAvailable -Name $mod) {
            Write-Verbose "  v $mod already installed"
            continue
        }
        Write-Host "  Installing PowerShell module $mod ..." -ForegroundColor Yellow
        try {
            Install-Module $mod -Scope CurrentUser -Force -AllowClobber -AcceptLicense -ErrorAction Stop
            Write-Host "  v $mod installed" -ForegroundColor Green
        } catch {
            Write-Warning (Remove-Credentials "Could not install $mod for ${ToolName}: $($_.Exception.Message). Run manually: Install-Module $mod -Scope CurrentUser")
        }
    }
}

function Invoke-PackageManager {
    <#
    .SYNOPSIS
        Runs a system package manager quietly and returns $true on success.
    #>
    param (
        [Parameter(Mandatory)][string] $Manager,
        [Parameter(Mandatory)][string] $Package
    )

    if ($script:AllowedPackageManagers -notcontains $Manager) {
        Write-Warning "Refusing to use disallowed package manager '$Manager'."
        return $false
    }
    if (-not (Test-SafePackageName -Name $Package)) {
        Write-Warning "Refusing to install package with unsafe name '$Package'."
        return $false
    }

    $mgrArgs = switch ($Manager) {
        'winget' { @('install', '--silent', '--accept-source-agreements', '--accept-package-agreements', '--id', $Package) }
        'brew'   { @('install', $Package) }
        'pipx'   { @('install', $Package) }
        'pip'    { @('install', '--user', $Package) }
        'snap'   { @('install', $Package) }
        default  { $null }
    }
    if (-not $mgrArgs) { return $false }
    if (-not (Test-CliAvailable -Command $Manager)) { return $false }

    $result = Invoke-WithTimeout -Command $Manager -Arguments $mgrArgs
    if ($result.ExitCode -eq 0) { return $true }
    Write-Verbose $result.Output
    return $false
}

function Install-CliTool {
    param (
        [Parameter(Mandatory)][PSCustomObject] $InstallSpec,
        [Parameter(Mandatory)][string] $ToolName,
        [string] $ManagerOverride
    )

    $cmd = $InstallSpec.command
    if (Test-CliAvailable -Command $cmd) {
        Write-Verbose "  v $cmd already installed"
        return $true
    }

    $os = Get-CurrentOS
    $osBlock = if ($InstallSpec.PSObject.Properties[$os]) { $InstallSpec.$os } else { $null }
    if (-not $osBlock) {
        Write-Warning "No install recipe for $ToolName on $os. Install $cmd manually."
        return $false
    }

    # Try manager override first (from install config)
    if ($ManagerOverride) {
        if ($script:AllowedPackageManagers -notcontains $ManagerOverride) {
            Write-Warning "[install-config] Manager override '$ManagerOverride' for $ToolName is not in the allow-list. Falling back to manifest."
        } elseif ($osBlock.PSObject.Properties[$ManagerOverride]) {
            $pkg = [string]$osBlock.$ManagerOverride
            Write-Host "  Installing $ToolName via $ManagerOverride (config override, $pkg) ..." -ForegroundColor Yellow
            if (Invoke-PackageManager -Manager $ManagerOverride -Package $pkg) {
                if (Test-CliAvailable -Command $cmd) {
                    Write-Host "  v $ToolName installed (config override)" -ForegroundColor Green
                    return $true
                }
            }
            Write-Verbose "[install-config] Override manager $ManagerOverride failed for $ToolName; falling back to manifest."
        } else {
            Write-Verbose "[install-config] Override manager $ManagerOverride has no package for $ToolName on $os; falling back to manifest."
        }
    }

    # Use preferredManagers from manifest when present (ordered list);
    # fall back to global allow-list otherwise. Defense-in-depth: each
    # manager is re-checked against the allow-list before use.
    $mgrList = $script:AllowedPackageManagers
    if ($InstallSpec.PSObject.Properties['preferredManagers'] -and $InstallSpec.preferredManagers) {
        $mgrList = @($InstallSpec.preferredManagers)
    }

    foreach ($mgr in $mgrList) {
        # Defense-in-depth: reject any manager not in the global allow-list,
        # even if it somehow ended up in preferredManagers.
        if ($script:AllowedPackageManagers -notcontains $mgr) {
            Write-Warning "Skipping disallowed manager '$mgr' in preferredManagers for $ToolName."
            continue
        }
        if ($osBlock.PSObject.Properties[$mgr]) {
            $pkg = [string]$osBlock.$mgr
            Write-Host "  Installing $ToolName via $mgr ($pkg) ..." -ForegroundColor Yellow
            if (Invoke-PackageManager -Manager $mgr -Package $pkg) {
                if (Test-CliAvailable -Command $cmd) {
                    Write-Host "  v $ToolName installed" -ForegroundColor Green
                    return $true
                }
                Write-Warning "$mgr install succeeded but $cmd still not on PATH. Open a new shell and re-run."
                return $false
            }
        }
    }

    if ($osBlock.PSObject.Properties['url']) {
        Write-Warning "No package manager available for $ToolName on $os. Download from: $($osBlock.url)"
    } else {
        Write-Warning "$ToolName could not be installed automatically. Install it manually."
    }
    return $false
}

function Install-GitClone {
    param (
        [Parameter(Mandatory)][PSCustomObject] $InstallSpec,
        [Parameter(Mandatory)][string] $ToolName,
        [Parameter(Mandatory)][string] $RepoRoot
    )

    $repoUrl = [string]$InstallSpec.repo
    if (-not (Test-SafeGitUrl -Url $repoUrl)) {
        Write-Warning "Refusing to clone $ToolName from disallowed URL '$repoUrl'. Allowed hosts: $($script:AllowedGitHosts -join ', ')."
        return $false
    }

    $targetRel = $InstallSpec.target
    $target = Join-Path $RepoRoot $targetRel
    $probeFile = Join-Path $target $InstallSpec.probe

    if (Test-Path $probeFile) {
        Write-Verbose "  v $ToolName already present at $targetRel"
        return $true
    }

    if (-not (Test-CliAvailable -Command 'git')) {
        Write-Warning "git not found -- cannot bootstrap $ToolName. Install git or clone $repoUrl to $targetRel manually."
        return $false
    }

    Write-Host "  Cloning $ToolName from $repoUrl ..." -ForegroundColor Yellow
    try {
        $parent = Split-Path $target -Parent
        if (-not (Test-Path $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
        # Remove any partial clone
        if (Test-Path $target) { Remove-Item $target -Recurse -Force -ErrorAction SilentlyContinue }
        $result = Invoke-WithTimeout -Command 'git' -Arguments @('clone', '--depth', '1', '--quiet', $repoUrl, $target)
        if ($result.ExitCode -ne 0 -or -not (Test-Path $probeFile)) {
            Write-Warning "git clone of $ToolName failed: $($result.Output)"
            return $false
        }
        Write-Host "  v $ToolName cloned into $targetRel" -ForegroundColor Green
        return $true
    } catch {
        Write-Warning (Remove-Credentials "Failed to clone ${ToolName}: $($_.Exception.Message)")
        return $false
    }
}

function Test-InstallConfig {
    <#
    .SYNOPSIS
        Validate an install config object against the expected schema.
        Returns a PSCustomObject with Valid (bool) and Errors (string[]).
    .PARAMETER Config
        The parsed install-config.json object.
    .PARAMETER Manifest
        The parsed tool-manifest.json object, used to validate tool names.
    #>
    param (
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] $Manifest
    )
    $errors = [System.Collections.Generic.List[string]]::new()

    # Schema version check
    $hasSchemaVer = $Config.PSObject.Properties['schemaVersion']
    if (-not $hasSchemaVer -or $Config.schemaVersion -ne '1.0') {
        $actual = if ($hasSchemaVer) { Remove-Credentials ([string]$Config.schemaVersion) } else { '<missing>' }
        $errors.Add("schemaVersion must be '1.0', got '${actual}'.")
    }

    # Validate defaults block
    if ($Config.PSObject.Properties['defaults']) {
        $defaults = $Config.defaults
        $allowedDefaultKeys = @('autoInstall')
        foreach ($prop in $defaults.PSObject.Properties) {
            if ($prop.Name -notin $allowedDefaultKeys) {
                $errors.Add("Unknown key 'defaults.$(Remove-Credentials $prop.Name)'.")
            }
        }
        if ($defaults.PSObject.Properties['autoInstall'] -and $defaults.autoInstall -isnot [bool]) {
            $errors.Add("defaults.autoInstall must be a boolean.")
        }
    }

    # Validate tools block
    if ($Config.PSObject.Properties['tools'] -and $null -ne $Config.tools) {
        $manifestNames = @($Manifest.tools | ForEach-Object { $_.name })
        $allowedToolKeys = @('enabled', 'manager')

        foreach ($prop in $Config.tools.PSObject.Properties) {
            $toolName = Remove-Credentials $prop.Name
            $toolCfg  = $prop.Value

            if ($prop.Name -notin $manifestNames) {
                $errors.Add("Tool '${toolName}' not found in tool-manifest.json.")
            }

            foreach ($k in $toolCfg.PSObject.Properties) {
                if ($k.Name -notin $allowedToolKeys) {
                    $errors.Add("Unknown key 'tools.${toolName}.$(Remove-Credentials $k.Name)'.")
                }
            }

            if ($toolCfg.PSObject.Properties['enabled'] -and $toolCfg.enabled -isnot [bool]) {
                $errors.Add("tools.${toolName}.enabled must be a boolean.")
            }

            if ($toolCfg.PSObject.Properties['manager']) {
                $mgr = Remove-Credentials ([string]$toolCfg.manager)
                if ($script:AllowedPackageManagers -notcontains $mgr) {
                    $errors.Add("tools.${toolName}.manager '${mgr}' is not in the allow-list ($($script:AllowedPackageManagers -join ', ')).")
                }
            }
        }
    }

    # Reject unknown top-level keys
    $allowedTopLevel = @('schemaVersion', 'defaults', 'tools')
    foreach ($prop in $Config.PSObject.Properties) {
        if ($prop.Name -notin $allowedTopLevel) {
            $errors.Add("Unknown top-level key '$(Remove-Credentials $prop.Name)'.")
        }
    }

    return [PSCustomObject]@{
        Valid  = ($errors.Count -eq 0)
        Errors = $errors.ToArray()
    }
}

function Read-InstallConfig {
    <#
    .SYNOPSIS
        Load and validate tools/install-config.json. Returns $null if the
        file is missing (backward-compatible) or invalid (warning emitted).
    .PARAMETER Path
        Path to the install-config.json file.
    .PARAMETER Manifest
        The parsed tool-manifest.json object, used for tool-name validation.
    #>
    param (
        [string] $Path,
        [Parameter(Mandatory)] $Manifest
    )

    if (-not $Path) { $Path = $script:DefaultInstallConfigPath }
    if (-not (Test-Path $Path)) {
        Write-Verbose "[install-config] No config file at $Path; using manifest defaults."
        return $null
    }

    try {
        $config = Get-Content $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Warning (Remove-Credentials "[install-config] Failed to parse ${Path}: $($_.Exception.Message). Using manifest defaults.")
        return $null
    }

    $validation = Test-InstallConfig -Config $config -Manifest $Manifest
    if (-not $validation.Valid) {
        foreach ($err in $validation.Errors) {
            Write-Warning (Remove-Credentials "[install-config] $err")
        }
        Write-Warning "[install-config] Config validation failed; falling back to manifest defaults."
        return $null
    }

    Write-Verbose "[install-config] Loaded install config from $Path"
    return $config
}

function Install-PrerequisitesFromManifest {
    <#
    .SYNOPSIS
        Install all prerequisites for enabled, non-excluded tools.
    .PARAMETER Manifest
        The parsed tool manifest object (from tool-manifest.json).
    .PARAMETER RepoRoot
        Repository root used as the base for gitclone targets.
    .PARAMETER ShouldRunTool
        Scriptblock that returns $true if a given tool name should run
        (honours -IncludeTools / -ExcludeTools in the caller).
    .PARAMETER SkipInstall
        When set, only reports what's missing without installing.
    .PARAMETER InstallConfig
        Optional parsed install-config.json object. Tools with
        enabled=false are skipped; manager overrides are applied.
    .PARAMETER CliIncludedTools
        Tool names explicitly passed via -IncludeTools. These override
        config enabled=false (CLI > config > manifest).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] $Manifest,
        [Parameter(Mandatory)][string] $RepoRoot,
        [Parameter(Mandatory)][scriptblock] $ShouldRunTool,
        [switch] $SkipInstall,
        $InstallConfig,
        [string[]] $CliIncludedTools
    )

    Write-Host "`n[prereq] Checking prerequisites (manifest-driven)..." -ForegroundColor Yellow
    $missing = [System.Collections.Generic.List[string]]::new()
    $skipped = [System.Collections.Generic.List[string]]::new()

    foreach ($tool in $Manifest.tools) {
        if (-not $tool.enabled) { continue }
        if (-not (& $ShouldRunTool $tool.name)) { continue }

        # Check install config for enabled=false override, but CLI
        # -IncludeTools takes precedence (CLI > config > manifest).
        $cliExplicit = $CliIncludedTools -and ($tool.name -in $CliIncludedTools)
        if (-not $cliExplicit -and
            $null -ne $InstallConfig -and
            $InstallConfig.PSObject.Properties['tools'] -and
            $null -ne $InstallConfig.tools -and
            $InstallConfig.tools.PSObject.Properties[$tool.name]) {
            $toolCfg = $InstallConfig.tools.($tool.name)
            if ($toolCfg.PSObject.Properties['enabled'] -and $toolCfg.enabled -eq $false) {
                Write-Verbose "[prereq] $($tool.name) disabled by install config; skipping."
                $skipped.Add($tool.name)
                continue
            }
        }

        if (-not $tool.PSObject.Properties['install'] -or -not $tool.install) { continue }
        $install = $tool.install
        $kind = [string]$install.kind

        if ($script:AllowedInstallKinds -notcontains $kind) {
            Write-Warning "Refusing to honour unknown install kind '$kind' for $($tool.name)."
            continue
        }

        # Resolve manager override from install config
        $managerOverride = $null
        if ($null -ne $InstallConfig -and
            $InstallConfig.PSObject.Properties['tools'] -and
            $null -ne $InstallConfig.tools -and
            $InstallConfig.tools.PSObject.Properties[$tool.name]) {
            $toolCfg = $InstallConfig.tools.($tool.name)
            if ($toolCfg.PSObject.Properties['manager']) {
                $managerOverride = [string]$toolCfg.manager
            }
        }

        switch ($kind) {
            'none' { }
            'psmodule' {
                $names = @($install.modules)
                $anyMissing = $false
                foreach ($m in $names) { if (-not (Test-PSModuleAvailable -Name $m)) { $anyMissing = $true; break } }
                if (-not $anyMissing) { break }
                if ($SkipInstall) {
                    $missing.Add("$($tool.displayName) ($($names -join ', '))")
                } else {
                    Install-PSModules -Names $names -ToolName $tool.displayName
                    foreach ($m in $names) {
                        if (-not (Test-PSModuleAvailable -Name $m)) { $missing.Add("$($tool.displayName) ($m)"); break }
                    }
                }
            }
            'cli' {
                if (Test-CliAvailable -Command $install.command) { break }
                if ($SkipInstall) {
                    $missing.Add("$($tool.displayName) ($($install.command))")
                } else {
                    $ok = Install-CliTool -InstallSpec $install -ToolName $tool.displayName -ManagerOverride $managerOverride
                    if (-not $ok) { $missing.Add($tool.displayName) }
                }
            }
            'gitclone' {
                $probe = Join-Path (Join-Path $RepoRoot $install.target) $install.probe
                if (Test-Path $probe) { break }
                if ($SkipInstall) {
                    $missing.Add("$($tool.displayName) ($($install.target))")
                } else {
                    $ok = Install-GitClone -InstallSpec $install -ToolName $tool.displayName -RepoRoot $RepoRoot
                    if (-not $ok) { $missing.Add($tool.displayName) }
                }
            }
        }
    }

    if ($skipped.Count -gt 0) {
        Write-Host "[prereq] $($skipped.Count) tool(s) disabled by install config: $($skipped -join ', ')" -ForegroundColor DarkGray
    }

    # Process top-level $Manifest.prerequisites (cross-tool helpers like
    # kubelogin that are not themselves tools but are required by one or
    # more wrappers). Honoured only when at least one consumer tool will run.
    if ($Manifest.PSObject.Properties['prerequisites'] -and $Manifest.prerequisites) {
        foreach ($prereq in $Manifest.prerequisites) {
            if (-not $prereq.PSObject.Properties['install'] -or -not $prereq.install) { continue }
            $install = $prereq.install
            $kind = [string]$install.kind
            if ($script:AllowedInstallKinds -notcontains $kind) {
                Write-Warning "Refusing to honour unknown install kind '$kind' for prereq $($prereq.name)."
                continue
            }
            # Only install if at least one consumer tool is going to run.
            $consumers = @($prereq.consumedBy)
            $anyConsumer = $false
            foreach ($c in $consumers) {
                if (& $ShouldRunTool $c) { $anyConsumer = $true; break }
            }
            if (-not $anyConsumer) { continue }

            switch ($kind) {
                'cli' {
                    if (Test-CliAvailable -Command $install.command) { break }
                    if ($SkipInstall) {
                        $missing.Add("$($prereq.displayName) ($($install.command))")
                    } else {
                        $ok = Install-CliTool -InstallSpec $install -ToolName $prereq.displayName
                        if (-not $ok) { $missing.Add($prereq.displayName) }
                    }
                }
                'psmodule' {
                    $names = @($install.modules)
                    $anyMissing = $false
                    foreach ($m in $names) { if (-not (Test-PSModuleAvailable -Name $m)) { $anyMissing = $true; break } }
                    if (-not $anyMissing) { break }
                    if ($SkipInstall) {
                        $missing.Add("$($prereq.displayName) ($($names -join ', '))")
                    } else {
                        Install-PSModules -Names $names -ToolName $prereq.displayName
                        foreach ($m in $names) {
                            if (-not (Test-PSModuleAvailable -Name $m)) { $missing.Add("$($prereq.displayName) ($m)"); break }
                        }
                    }
                }
                default { }
            }
        }
    }

    if ($missing.Count -gt 0) {
        Write-Host "`n[prereq] $($missing.Count) tool(s) still missing: $($missing -join '; ')" -ForegroundColor DarkYellow
    } else {
        Write-Host "[prereq] All prerequisites for enabled tools are available." -ForegroundColor Green
    }
    return $missing.Count
}