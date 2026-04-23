#Requires -Version 7.4
[CmdletBinding()]
param ()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Dot-source the merged ReportManifest module so the viewer uses the canonical
# Select-ReportArchitecture / Test-ReportArchitectureConfig contract from #456
# instead of the previous local stub (Phase 0 contract drift fix).
$script:ReportManifestPath = Join-Path $PSScriptRoot 'ReportManifest.ps1'
if (Test-Path -LiteralPath $script:ReportManifestPath) {
    . $script:ReportManifestPath
}

if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param ([string]$Text) return $Text }
}

if (-not (Get-Variable -Scope Script -Name AzureAnalyzerViewerState -ErrorAction SilentlyContinue)) {
    $script:AzureAnalyzerViewerState = [ordered]@{
        IsRunning = $false
        Port      = $null
        Address   = '127.0.0.1'
        Token     = $null
        Tier      = $null
        Job       = $null
    }
}

$script:MaxViewerEntityIdLength = 512
$script:ViewerTriageResponseMaxLength = 1000
$script:ViewerStartupTimeoutSeconds = 10
$script:ViewerHealthPollIntervalMs = 200

function Get-ViewerCollectionCount {
    [CmdletBinding()]
    param (
        [AllowNull()]
        [object] $Collection
    )

    if ($null -eq $Collection) { return 0 }
    if ($Collection -is [string]) { return 1 }
    if ($Collection -is [System.Collections.IEnumerable]) { return @($Collection).Count }
    return 1
}

function Get-ViewerJsonCount {
    [CmdletBinding()]
    param (
        [string] $Path,
        [string[]] $PropertyPreference,
        # When the JSON root is a bare array (e.g. v3.0 entities.json which is just an
        # array of entities), should the array length count for this axis? True for the
        # Entities/Findings axis, false for the Edges axis (bare array has no edges).
        [bool] $ArrayIsAxis = $true
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return 0
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return 0 }
        $json = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return 0
    }

    # ConvertFrom-Json yields Object[] for bare arrays and PSCustomObject for objects.
    if ($json -is [array]) {
        if ($ArrayIsAxis) {
            return (Get-ViewerCollectionCount -Collection $json)
        }
        return 0
    }

    foreach ($prop in @($PropertyPreference)) {
        if ($json -and $json.PSObject.Properties[$prop]) {
            return (Get-ViewerCollectionCount -Collection $json.$prop)
        }
    }

    if ($ArrayIsAxis) {
        return (Get-ViewerCollectionCount -Collection $json)
    }
    return 0
}

function Resolve-ViewerArchitecture {
    [CmdletBinding()]
    param (
        [string] $FindingsPath,
        [string] $EntitiesPath,
        [double] $HeadroomFactor = 1.25,
        [int] $FindingCount = -1,
        [int] $EntityCount = -1,
        [int] $EdgeCount = -1,
        [object] $ArchitectureConfig
    )

    $resolvedFindings = if ($FindingCount -ge 0) {
        $FindingCount
    } else {
        Get-ViewerJsonCount -Path $FindingsPath -PropertyPreference @('Findings', 'findings') -ArrayIsAxis:$true
    }
    $resolvedEntities = if ($EntityCount -ge 0) {
        $EntityCount
    } else {
        Get-ViewerJsonCount -Path $EntitiesPath -PropertyPreference @('Entities', 'entities') -ArrayIsAxis:$true
    }
    $resolvedEdges = if ($EdgeCount -ge 0) {
        $EdgeCount
    } else {
        # v3.0 bare-array entities.json has no edges; only v3.1 envelope objects with
        # an explicit Edges property report nonzero edges.
        Get-ViewerJsonCount -Path $EntitiesPath -PropertyPreference @('Edges', 'edges') -ArrayIsAxis:$false
    }

    $params = @{
        FindingCount   = [int]$resolvedFindings
        EntityCount    = [int]$resolvedEntities
        EdgeCount      = [int]$resolvedEdges
        HeadroomFactor = $HeadroomFactor
    }
    if ($ArchitectureConfig) { $params['ArchitectureConfig'] = $ArchitectureConfig }
    return Select-ReportArchitecture @params
}

function Test-LoopbackBind {
    [CmdletBinding()]
    param ([string] $Address)
    if ([string]::IsNullOrWhiteSpace($Address)) { return $false }
    $value = $Address.Trim().ToLowerInvariant()
    return $value -eq '127.0.0.1' -or $value -eq 'localhost'
}

function Test-HostHeader {
    [CmdletBinding()]
    param (
        [string] $HostHeader,
        [ValidateRange(1, 65535)]
        [int] $Port
    )

    if ([string]::IsNullOrWhiteSpace($HostHeader)) { return $false }
    $value = $HostHeader.Trim().ToLowerInvariant()
    return $value -eq "127.0.0.1:$Port" -or $value -eq "localhost:$Port" -or $value -eq '127.0.0.1' -or $value -eq 'localhost'
}

function Test-OriginHeader {
    [CmdletBinding()]
    param (
        [AllowNull()]
        [string] $Origin,
        [ValidateRange(1, 65535)]
        [int] $Port
    )

    if ([string]::IsNullOrWhiteSpace($Origin)) { return $true }
    try {
        $originUri = [uri]$Origin
    } catch {
        return $false
    }

    if ($originUri.Scheme -ne 'http') { return $false }
    if ($originUri.Port -ne $Port) { return $false }
    return $originUri.Host -eq '127.0.0.1' -or $originUri.Host -eq 'localhost'
}

function Test-CsrfToken {
    [CmdletBinding()]
    param (
        [AllowNull()]
        [string] $ProvidedToken,
        [AllowNull()]
        [string] $ExpectedToken
    )

    if ([string]::IsNullOrWhiteSpace($ProvidedToken) -or [string]::IsNullOrWhiteSpace($ExpectedToken)) {
        return $false
    }

    $providedBytes = [System.Text.Encoding]::UTF8.GetBytes($ProvidedToken)
    $expectedBytes = [System.Text.Encoding]::UTF8.GetBytes($ExpectedToken)
    $max = [Math]::Max($providedBytes.Length, $expectedBytes.Length)
    $diff = $providedBytes.Length -bxor $expectedBytes.Length
    for ($i = 0; $i -lt $max; $i++) {
        $p = if ($i -lt $providedBytes.Length) { $providedBytes[$i] } else { 0 }
        $e = if ($i -lt $expectedBytes.Length) { $expectedBytes[$i] } else { 0 }
        $diff = $diff -bor ($p -bxor $e)
    }

    return $diff -eq 0
}

function Get-ViewerCookieValue {
    [CmdletBinding()]
    param (
        [AllowNull()]
        [string] $CookieHeader,
        [Parameter(Mandatory)]
        [string] $Name
    )

    if ([string]::IsNullOrWhiteSpace($CookieHeader)) { return $null }
    foreach ($pair in ($CookieHeader -split ';')) {
        $kv = $pair.Trim()
        if ($kv -match "^$([regex]::Escape($Name))=(.*)$") {
            return $matches[1]
        }
    }
    return $null
}

function Test-ViewerSessionAuth {
    [CmdletBinding()]
    param (
        [AllowNull()] [string] $CookieHeader,
        [AllowNull()] [string] $TokenHeader,
        [Parameter(Mandatory)] [string] $ExpectedToken
    )

    $cookieVal = Get-ViewerCookieValue -CookieHeader $CookieHeader -Name 'aa_session'
    if ($cookieVal -and (Test-CsrfToken -ProvidedToken $cookieVal -ExpectedToken $ExpectedToken)) {
        return $true
    }
    if ($TokenHeader -and (Test-CsrfToken -ProvidedToken $TokenHeader -ExpectedToken $ExpectedToken)) {
        return $true
    }
    return $false
}

function Test-EntityIdSafe {
    [CmdletBinding()]
    param (
        [AllowNull()]
        [string] $EntityId
    )

    if ([string]::IsNullOrWhiteSpace($EntityId)) { return $false }
    if ($EntityId.Length -gt $script:MaxViewerEntityIdLength) { return $false }
    if ($EntityId -match '(\.\.|[\r\n])') { return $false }
    return $EntityId -match '^[a-zA-Z0-9:/._\-]+$'
}

function Test-ViewerPortAvailable {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string] $Address,
        [Parameter(Mandatory)] [ValidateRange(1, 65535)] [int] $Port
    )

    try {
        $ip = [System.Net.IPAddress]::Loopback
        if ($Address -ne '127.0.0.1' -and $Address -ne 'localhost') {
            $ip = [System.Net.IPAddress]::Parse($Address)
        }
        $listener = [System.Net.Sockets.TcpListener]::new($ip, $Port)
        $listener.Start()
        $listener.Stop()
        return $true
    } catch {
        return $false
    }
}

function Wait-ViewerHealthReady {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)] [string] $HealthUrl,
        [int] $TimeoutSeconds = 10
    )

    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([datetime]::UtcNow -lt $deadline) {
        try {
            $resp = Invoke-WebRequest -Uri $HealthUrl -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            if ($resp.StatusCode -eq 200) { return $true }
        } catch {
            Start-Sleep -Milliseconds $script:ViewerHealthPollIntervalMs
        }
    }
    return $false
}

function Set-ViewerTokenFileAcl {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    if ($IsWindows) {
        if (-not $PSCmdlet.ShouldProcess($Path, 'Restrict ACL to current user only')) { return $false }
        try {
            $acl = New-Object System.Security.AccessControl.FileSecurity
            $acl.SetAccessRuleProtection($true, $false)
            $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sid,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.AccessControlType]::Allow
            )
            $acl.AddAccessRule($rule)
            Set-Acl -LiteralPath $Path -AclObject $acl
            return $true
        } catch {
            return $false
        }
    }

    if (-not $PSCmdlet.ShouldProcess($Path, 'chmod 600')) { return $false }
    try {
        & chmod 600 $Path 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Start-AzureAnalyzerViewer {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [string] $OutputPath = (Join-Path $PWD 'output'),
        [ValidateRange(1, 65535)]
        [int] $Port = 4280,
        [string] $BindAddress = '127.0.0.1'
    )

    if (-not (Test-LoopbackBind -Address $BindAddress)) {
        throw "Viewer bind address must be loopback-only (127.0.0.1)."
    }

    if (-not $PSCmdlet.ShouldProcess("http://${BindAddress}:$Port/", 'Start azure-analyzer viewer')) {
        return $null
    }

    if ($script:AzureAnalyzerViewerState.Job) {
        $existing = $script:AzureAnalyzerViewerState.Job
        if ($existing.PSObject.Properties['State'] -and $existing.State -eq 'Running') {
            $existingUrl = "http://$($script:AzureAnalyzerViewerState.Address):$($script:AzureAnalyzerViewerState.Port)/"
            $existingToken = [string]$script:AzureAnalyzerViewerState.Token
            return [pscustomobject]@{
                Url       = $existingUrl
                AuthUrl   = "${existingUrl}auth?t=$existingToken"
                HealthUrl = "http://$($script:AzureAnalyzerViewerState.Address):$($script:AzureAnalyzerViewerState.Port)/api/health"
                Token     = $existingToken
                Tier      = $script:AzureAnalyzerViewerState.Tier
                JobId     = $existing.Id
            }
        }
        Remove-Job -Job $existing -Force -ErrorAction SilentlyContinue
        $script:AzureAnalyzerViewerState.Job = $null
    }

    if (-not (Test-ViewerPortAvailable -Address $BindAddress -Port $Port)) {
        throw "Viewer port $Port on $BindAddress is already in use. Choose a different -ViewerPort."
    }

    if (-not (Get-Command Start-PodeServer -ErrorAction SilentlyContinue)) {
        try {
            Import-Module Pode -ErrorAction Stop
        } catch {
            throw "Pode module is required but not found. In interactive environments, run: Install-Module Pode -Scope CurrentUser. In CI or restricted environments, pre-install Pode in the runner image."
        }
    }

    $findingsPath = Join-Path $OutputPath 'results.json'
    $entitiesPath = Join-Path $OutputPath 'entities.json'
    $triagePath = Join-Path $OutputPath 'triage.json'
    $arch = Resolve-ViewerArchitecture -FindingsPath $findingsPath -EntitiesPath $entitiesPath
    $token = [Guid]::NewGuid().ToString('N')
    $modulePath = $PSCommandPath
    $archJson = $arch | ConvertTo-Json -Depth 8 -Compress

    $viewerJob = Start-Job -Name "azure-analyzer-viewer-$Port" -ScriptBlock {
        param ($ModulePath, $BindAddress, $Port, $Token, $ArchitectureJson, $TriagePath)
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        . $ModulePath
        Import-Module Pode -ErrorAction Stop
        $architecture = $ArchitectureJson | ConvertFrom-Json -ErrorAction Stop

        Start-PodeServer -Threads 1 -ScriptBlock {
            Add-PodeEndpoint -Address $using:BindAddress -Port $using:Port -Protocol Http

            Add-PodeRoute -Method Get -Path '/api/health' -ScriptBlock {
                $hostHeader = [string]$WebEvent.Request.Headers['Host']
                if (-not (Test-HostHeader -HostHeader $hostHeader -Port $using:Port)) {
                    Set-PodeResponseStatus -Code 400
                    Write-PodeJsonResponse -Value @{ error = 'invalid_host' }
                    return
                }
                Write-PodeJsonResponse -StatusCode 200 -Value @{
                    status = 'ok'
                    tier   = $using:architecture.Tier
                }
            }

            Add-PodeRoute -Method Get -Path '/auth' -ScriptBlock {
                $hostHeader = [string]$WebEvent.Request.Headers['Host']
                if (-not (Test-HostHeader -HostHeader $hostHeader -Port $using:Port)) {
                    Set-PodeResponseStatus -Code 400
                    Write-PodeJsonResponse -Value @{ error = 'invalid_host' }
                    return
                }
                $providedToken = [string]$WebEvent.Query['t']
                if (-not (Test-CsrfToken -ProvidedToken $providedToken -ExpectedToken $using:Token)) {
                    Set-PodeResponseStatus -Code 403
                    Write-PodeJsonResponse -Value @{ error = 'invalid_token' }
                    return
                }
                # Set HttpOnly, SameSite=Strict, Path=/ session cookie. Browsers attach it
                # automatically on subsequent same-origin navigations and fetches, removing
                # the need for the user to set X-Session-Token by hand.
                $cookieValue = "aa_session=$using:Token; HttpOnly; SameSite=Strict; Path=/"
                Add-PodeHeader -Name 'Set-Cookie' -Value $cookieValue
                Move-PodeResponseUrl -Url '/'
            }

            Add-PodeRoute -Method Get -Path '/api/triage' -ScriptBlock {
                $hostHeader = [string]$WebEvent.Request.Headers['Host']
                if (-not (Test-HostHeader -HostHeader $hostHeader -Port $using:Port)) {
                    Set-PodeResponseStatus -Code 400
                    Write-PodeJsonResponse -Value @{ error = 'invalid_host' }
                    return
                }
                $originHeader = [string]$WebEvent.Request.Headers['Origin']
                if (-not (Test-OriginHeader -Origin $originHeader -Port $using:Port)) {
                    Set-PodeResponseStatus -Code 403
                    Write-PodeJsonResponse -Value @{ error = 'invalid_origin' }
                    return
                }
                $cookieHeader = [string]$WebEvent.Request.Headers['Cookie']
                $tokenHeader = [string]$WebEvent.Request.Headers['X-Session-Token']
                if (-not (Test-ViewerSessionAuth -CookieHeader $cookieHeader -TokenHeader $tokenHeader -ExpectedToken $using:Token)) {
                    Set-PodeResponseStatus -Code 403
                    Write-PodeJsonResponse -Value @{ error = 'invalid_token' }
                    return
                }
                $payload = $null
                if (Test-Path -LiteralPath $using:TriagePath) {
                    try {
                        $payload = Get-Content -LiteralPath $using:TriagePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
                    } catch {
                        $payload = [pscustomobject]@{ error = 'triage_parse_failed' }
                    }
                }
                Write-PodeJsonResponse -StatusCode 200 -Value @{
                    hasTriage = ($null -ne $payload)
                    triage    = $payload
                }
            }

            Add-PodeRoute -Method Get -Path '/' -ScriptBlock {
                $hostHeader = [string]$WebEvent.Request.Headers['Host']
                if (-not (Test-HostHeader -HostHeader $hostHeader -Port $using:Port)) {
                    Set-PodeResponseStatus -Code 400
                    Write-PodeJsonResponse -Value @{ error = 'invalid_host' }
                    return
                }

                $originHeader = [string]$WebEvent.Request.Headers['Origin']
                if (-not (Test-OriginHeader -Origin $originHeader -Port $using:Port)) {
                    Set-PodeResponseStatus -Code 403
                    Write-PodeJsonResponse -Value @{ error = 'invalid_origin' }
                    return
                }

                $cookieHeader = [string]$WebEvent.Request.Headers['Cookie']
                $tokenHeader = [string]$WebEvent.Request.Headers['X-Session-Token']
                if (-not (Test-ViewerSessionAuth -CookieHeader $cookieHeader -TokenHeader $tokenHeader -ExpectedToken $using:Token)) {
                    Set-PodeResponseStatus -Code 403
                    Write-PodeJsonResponse -Value @{ error = 'invalid_token' }
                    return
                }

                $triageHtml = "<p>No triage data for this run.</p>"
                if (Test-Path -LiteralPath $using:TriagePath) {
                    try {
                        $triage = Get-Content -LiteralPath $using:TriagePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
                        $mode = if ($triage.PSObject.Properties['Mode']) { [string]$triage.Mode } else { 'Unknown' }
                        $models = if ($triage.PSObject.Properties['SelectedModels']) { (@($triage.SelectedModels) -join ', ') } else { '' }
                        $response = if ($triage.PSObject.Properties['Response']) { [string]$triage.Response } else { '' }
                        if ($response.Length -gt $script:ViewerTriageResponseMaxLength) {
                            $response = $response.Substring(0, $script:ViewerTriageResponseMaxLength) + '...[TRUNCATED]'
                        }
                        $safeMode = (Remove-Credentials $mode).Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
                        $safeModels = (Remove-Credentials $models).Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
                        $safeResponse = (Remove-Credentials $response).Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
                        $triageHtml = "<p><strong>Mode:</strong> $safeMode<br><strong>Models:</strong> $safeModels</p><pre>$safeResponse</pre>"
                    } catch {
                        $triageHtml = '<p>Triage output present but could not be parsed.</p>'
                    }
                }

                $html = @"
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>azure-analyzer viewer</title></head>
<body><h1>azure-analyzer findings viewer</h1><p>Tier: $($using:architecture.Tier)</p><section id='triage-panel'><h2>Triage</h2>$triageHtml</section></body>
</html>
"@
                Write-PodeHtmlResponse -Value $html
            }
        }
    } -ArgumentList $modulePath, $BindAddress, $Port, $token, $archJson, $triagePath

    if ($viewerJob -is [System.Management.Automation.Job]) {
        $deadline = [datetime]::UtcNow.AddSeconds($script:ViewerStartupTimeoutSeconds)
        while ($viewerJob.State -eq 'NotStarted') {
            if ([datetime]::UtcNow -ge $deadline) { break }
            Start-Sleep -Milliseconds 200
            $viewerJob = Get-Job -Id $viewerJob.Id -ErrorAction SilentlyContinue
            if (-not $viewerJob) { break }
        }
    }

    if ($null -ne $viewerJob -and $viewerJob.PSObject.Properties['State'] -and $viewerJob.State -eq 'Failed') {
        $jobError = (Receive-Job -Job $viewerJob -Keep -ErrorAction SilentlyContinue | Out-String).Trim()
        Remove-Job -Job $viewerJob -Force -ErrorAction SilentlyContinue
        throw (Remove-Credentials "Viewer failed to start: $jobError")
    }

    $healthUrl = "http://${BindAddress}:$Port/api/health"
    if ($viewerJob -is [System.Management.Automation.Job]) {
        if (-not (Wait-ViewerHealthReady -HealthUrl $healthUrl -TimeoutSeconds $script:ViewerStartupTimeoutSeconds)) {
            $jobError = (Receive-Job -Job $viewerJob -Keep -ErrorAction SilentlyContinue | Out-String).Trim()
            Stop-Job -Job $viewerJob -ErrorAction SilentlyContinue
            Remove-Job -Job $viewerJob -Force -ErrorAction SilentlyContinue
            throw (Remove-Credentials "Viewer did not become ready within $($script:ViewerStartupTimeoutSeconds)s: $jobError")
        }
    }

    $script:AzureAnalyzerViewerState.IsRunning = $true
    $script:AzureAnalyzerViewerState.Port = $Port
    $script:AzureAnalyzerViewerState.Address = $BindAddress
    $script:AzureAnalyzerViewerState.Token = $token
    $script:AzureAnalyzerViewerState.Tier = $arch.Tier
    $script:AzureAnalyzerViewerState.Job = $viewerJob

    $rootUrl = "http://${BindAddress}:$Port/"
    return [pscustomobject]@{
        Url       = $rootUrl
        AuthUrl   = "http://${BindAddress}:$Port/auth?t=$token"
        HealthUrl = $healthUrl
        Token     = $token
        Tier      = $arch.Tier
        JobId     = if ($viewerJob -and $viewerJob.PSObject.Properties['Id']) { $viewerJob.Id } else { $null }
    }
}

function Stop-AzureAnalyzerViewer {
    [CmdletBinding(SupportsShouldProcess)]
    param ()

    if (-not $script:AzureAnalyzerViewerState.Job) {
        $script:AzureAnalyzerViewerState.IsRunning = $false
        return $false
    }

    if (-not $PSCmdlet.ShouldProcess('azure-analyzer viewer', 'Stop background job and clear state')) {
        return $false
    }

    $job = $script:AzureAnalyzerViewerState.Job
    $jobId = if ($job.PSObject.Properties['Id']) { [int]$job.Id } else { $null }
    $isTypedJob = $job -is [System.Management.Automation.Job]

    if ($job.PSObject.Properties['State'] -and $job.State -eq 'Running') {
        if ($isTypedJob) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
        } elseif ($null -ne $jobId) {
            Stop-Job -Id $jobId -ErrorAction SilentlyContinue
        }
    }

    if ($isTypedJob) {
        Receive-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    } elseif ($null -ne $jobId) {
        Receive-Job -Id $jobId -ErrorAction SilentlyContinue | Out-Null
        Remove-Job -Id $jobId -Force -ErrorAction SilentlyContinue
    }

    $script:AzureAnalyzerViewerState.IsRunning = $false
    $script:AzureAnalyzerViewerState.Port = $null
    $script:AzureAnalyzerViewerState.Token = $null
    $script:AzureAnalyzerViewerState.Tier = $null
    $script:AzureAnalyzerViewerState.Job = $null

    return $true
}
