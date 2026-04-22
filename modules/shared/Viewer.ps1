#Requires -Version 7.4
[CmdletBinding()]
param ()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
        [string[]] $PropertyPreference
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

    foreach ($prop in @($PropertyPreference)) {
        if ($json -and $json.PSObject.Properties[$prop]) {
            return (Get-ViewerCollectionCount -Collection $json.$prop)
        }
    }

    return (Get-ViewerCollectionCount -Collection $json)
}

function Select-ReportArchitecture {
    [CmdletBinding()]
    param (
        [string] $FindingsPath,
        [string] $EntitiesPath,
        [ValidateRange(1.0, 10.0)]
        [double] $HeadroomMultiplier = 1.25,
        [int] $FindingCount = -1,
        [int] $EntityCount = -1,
        [int] $EdgeCount = -1,
        [hashtable] $Thresholds
    )

    # Stub thresholds for #430 while Foundation interfaces (#456) are in-flight.
    # Wire this to Foundation count providers once they are available.
    $defaultThresholds = [ordered]@{
        'Tier1' = @{ Findings = 2000; Entities = 1000; Edges = 5000 }
        'Tier2' = @{ Findings = 10000; Entities = 5000; Edges = 25000 }
        'Tier3' = @{ Findings = 50000; Entities = 25000; Edges = 100000 }
        'Tier4' = @{ Findings = [int]::MaxValue; Entities = [int]::MaxValue; Edges = [int]::MaxValue }
    }
    $effectiveThresholds = if ($Thresholds -and $Thresholds.Count -gt 0) { $Thresholds } else { $defaultThresholds }

    $resolvedFindings = if ($FindingCount -ge 0) { $FindingCount } else { Get-ViewerJsonCount -Path $FindingsPath -PropertyPreference @('Findings', 'findings') }
    $resolvedEntities = if ($EntityCount -ge 0) { $EntityCount } else { Get-ViewerJsonCount -Path $EntitiesPath -PropertyPreference @('Entities', 'entities') }
    $resolvedEdges = if ($EdgeCount -ge 0) { $EdgeCount } else { Get-ViewerJsonCount -Path $EntitiesPath -PropertyPreference @('Edges', 'edges') }

    $projectedFindings = [int][Math]::Ceiling($resolvedFindings * $HeadroomMultiplier)
    $projectedEntities = [int][Math]::Ceiling($resolvedEntities * $HeadroomMultiplier)
    $projectedEdges = [int][Math]::Ceiling($resolvedEdges * $HeadroomMultiplier)

    $selectedTier = 'Tier4'
    foreach ($tier in $effectiveThresholds.Keys) {
        $limits = $effectiveThresholds[$tier]
        if (-not $limits) { continue }
        if ($projectedFindings -le [int]$limits.Findings -and
            $projectedEntities -le [int]$limits.Entities -and
            $projectedEdges -le [int]$limits.Edges) {
            $selectedTier = [string]$tier
            break
        }
    }

    return [pscustomobject]@{
        Tier                = $selectedTier
        Findings            = [int]$resolvedFindings
        Entities            = [int]$resolvedEntities
        Edges               = [int]$resolvedEdges
        ProjectedFindings   = $projectedFindings
        ProjectedEntities   = $projectedEntities
        ProjectedEdges      = $projectedEdges
        HeadroomMultiplier  = $HeadroomMultiplier
        Thresholds          = $effectiveThresholds
        ThresholdsAreStub   = $true
    }
}

function Test-LoopbackBind {
    [CmdletBinding()]
    param ([string] $Address)
    return -not [string]::IsNullOrWhiteSpace($Address) -and $Address.Trim().ToLowerInvariant() -eq '127.0.0.1'
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

function Test-EntityIdSafe {
    [CmdletBinding()]
    param (
        [AllowNull()]
        [string] $EntityId
    )

    if ([string]::IsNullOrWhiteSpace($EntityId)) { return $false }
    if ($EntityId.Length -gt 512) { return $false }
    if ($EntityId -match '\.\.' -or $EntityId -match '[\r\n]') { return $false }
    return $EntityId -match '^[a-zA-Z0-9:/._|#@-]+$'
}

function Start-AzureAnalyzerViewer {
    [CmdletBinding()]
    param (
        [string] $OutputPath = (Join-Path $PWD 'output'),
        [ValidateRange(1, 65535)]
        [int] $Port = 4280,
        [string] $BindAddress = '127.0.0.1'
    )

    if (-not (Test-LoopbackBind -Address $BindAddress)) {
        throw "Viewer bind address must be loopback-only (127.0.0.1)."
    }

    if ($script:AzureAnalyzerViewerState.Job) {
        $existing = $script:AzureAnalyzerViewerState.Job
        if ($existing.State -eq 'Running') {
            return [pscustomobject]@{
                Url       = "http://$($script:AzureAnalyzerViewerState.Address):$($script:AzureAnalyzerViewerState.Port)/"
                HealthUrl = "http://$($script:AzureAnalyzerViewerState.Address):$($script:AzureAnalyzerViewerState.Port)/api/health"
                Token     = $script:AzureAnalyzerViewerState.Token
                Tier      = $script:AzureAnalyzerViewerState.Tier
                JobId     = $existing.Id
            }
        }
        Remove-Job -Job $existing -Force -ErrorAction SilentlyContinue
        $script:AzureAnalyzerViewerState.Job = $null
    }

    if (-not (Get-Command Start-PodeServer -ErrorAction SilentlyContinue)) {
        try {
            Import-Module Pode -ErrorAction Stop
        } catch {
            throw "Pode is required to launch the viewer. Install-Module Pode -Scope CurrentUser"
        }
    }

    $findingsPath = Join-Path $OutputPath 'results.json'
    $entitiesPath = Join-Path $OutputPath 'entities.json'
    $arch = Select-ReportArchitecture -FindingsPath $findingsPath -EntitiesPath $entitiesPath
    $token = [Guid]::NewGuid().ToString('N')
    $modulePath = $PSCommandPath
    $archJson = $arch | ConvertTo-Json -Depth 8 -Compress

    $viewerJob = Start-Job -Name "azure-analyzer-viewer-$Port" -ScriptBlock {
        param ($ModulePath, $BindAddress, $Port, $Token, $ArchitectureJson)
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        . $ModulePath
        Import-Module Pode -ErrorAction Stop
        $architecture = $ArchitectureJson | ConvertFrom-Json -ErrorAction Stop

        Start-PodeServer -Threads 1 -ScriptBlock {
            Add-PodeEndpoint -Address $using:BindAddress -Port $using:Port -Protocol Http

            Add-PodeRoute -Method Get -Path '/api/health' -ScriptBlock {
                Write-PodeJsonResponse -StatusCode 200 -Value @{
                    status = 'ok'
                    tier   = $using:architecture.Tier
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

                $tokenHeader = [string]$WebEvent.Request.Headers['X-Session-Token']
                if (-not (Test-CsrfToken -ProvidedToken $tokenHeader -ExpectedToken $using:Token)) {
                    Set-PodeResponseStatus -Code 403
                    Write-PodeJsonResponse -Value @{ error = 'invalid_token' }
                    return
                }

                $html = @"
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>azure-analyzer viewer</title></head>
<body><h1>azure-analyzer findings viewer</h1><p>Tier: $($using:architecture.Tier)</p></body>
</html>
"@
                Write-PodeHtmlResponse -Value $html
            }
        }
    } -ArgumentList $modulePath, $BindAddress, $Port, $token, $archJson

    Start-Sleep -Milliseconds 400
    if ($viewerJob.State -eq 'Failed') {
        $jobError = (Receive-Job -Job $viewerJob -Keep -ErrorAction SilentlyContinue | Out-String).Trim()
        Remove-Job -Job $viewerJob -Force -ErrorAction SilentlyContinue
        throw "Viewer failed to start: $jobError"
    }

    $script:AzureAnalyzerViewerState.IsRunning = $true
    $script:AzureAnalyzerViewerState.Port = $Port
    $script:AzureAnalyzerViewerState.Address = $BindAddress
    $script:AzureAnalyzerViewerState.Token = $token
    $script:AzureAnalyzerViewerState.Tier = $arch.Tier
    $script:AzureAnalyzerViewerState.Job = $viewerJob

    return [pscustomobject]@{
        Url       = "http://${BindAddress}:$Port/"
        HealthUrl = "http://${BindAddress}:$Port/api/health"
        Token     = $token
        Tier      = $arch.Tier
        JobId     = $viewerJob.Id
    }
}

function Stop-AzureAnalyzerViewer {
    [CmdletBinding()]
    param ()

    if (-not $script:AzureAnalyzerViewerState.Job) {
        $script:AzureAnalyzerViewerState.IsRunning = $false
        return $false
    }

    $job = $script:AzureAnalyzerViewerState.Job
    $jobId = if ($job.PSObject.Properties['Id']) { [int]$job.Id } else { $null }
    $isTypedJob = $job -is [System.Management.Automation.Job]

    if ($job.State -eq 'Running') {
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
