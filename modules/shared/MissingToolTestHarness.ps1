#Requires -Version 7.0

function Invoke-WrapperWithoutTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $WrapperPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ToolName,

        [hashtable] $WrapperArguments = @{}
    )

    if (-not (Test-Path -LiteralPath $WrapperPath -PathType Leaf)) {
        throw "Wrapper path does not exist: $WrapperPath"
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "aa-missing-tool-$([Guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Path $tempRoot -Force

    $childScriptPath = Join-Path $tempRoot 'invoke-wrapper.ps1'
    $wrapperArgsPath = Join-Path $tempRoot 'wrapper-args.json'
    $payloadPath = Join-Path $tempRoot 'payload.json'
    $stdoutPath = Join-Path $tempRoot 'stdout.log'
    $stderrPath = Join-Path $tempRoot 'stderr.log'

    try {
        [PSCustomObject]$WrapperArguments |
            ConvertTo-Json -Depth 30 -Compress |
            Set-Content -Path $wrapperArgsPath -Encoding UTF8 -NoNewline

        @'
param(
    [string] $WrapperPath,
    [string] $ToolName,
    [string] $WrapperArgsPath,
    [string] $PayloadPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$WarningPreference = 'Continue'

# Clear both keys to handle POSIX-style PATH and Windows-style Path casing.
$env:PATH = ''
$env:Path = ''
Remove-Item Env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS -ErrorAction SilentlyContinue
Remove-Item Env:AZURE_ANALYZER_ORCHESTRATED -ErrorAction SilentlyContinue
Remove-Item Env:AZURE_ANALYZER_EXPLICIT_TOOLS -ErrorAction SilentlyContinue

$wrapperArgs = @{}
if (Test-Path -LiteralPath $WrapperArgsPath -PathType Leaf) {
    $rawArgs = Get-Content -LiteralPath $WrapperArgsPath -Raw
    if (-not [string]::IsNullOrWhiteSpace($rawArgs)) {
        $wrapperArgs = ConvertFrom-Json -InputObject $rawArgs -AsHashtable
    }
}

$warnings = @()
$envelope = $null
$exitCode = 0

try {
    $envelope = & $WrapperPath @wrapperArgs -WarningVariable warnings -WarningAction Continue
} catch {
    $exitCode = 1
    [Console]::Error.WriteLine(($_ | Out-String))
}

$warningMessages = @()
foreach ($w in @($warnings)) {
    if ($w -is [System.Management.Automation.WarningRecord]) {
        $warningMessages += [string]$w.Message
    } elseif ($null -ne $w) {
        $warningMessages += [string]$w
    }
}

[PSCustomObject]@{
    ExitCode = $exitCode
    ToolName = $ToolName
    Warnings = @($warningMessages)
    Envelope = $envelope
} | ConvertTo-Json -Depth 100 | Set-Content -Path $PayloadPath -Encoding UTF8 -NoNewline

exit $exitCode
'@ | Set-Content -Path $childScriptPath -Encoding UTF8

        $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
        $process = Start-Process -FilePath $pwsh -ArgumentList @(
            '-NoLogo',
            '-NoProfile',
            '-NonInteractive',
            '-File', $childScriptPath,
            '-WrapperPath', $WrapperPath,
            '-ToolName', $ToolName,
            '-WrapperArgsPath', $wrapperArgsPath,
            '-PayloadPath', $payloadPath
        ) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

        $payload = if (Test-Path -LiteralPath $payloadPath -PathType Leaf) {
            Get-Content -LiteralPath $payloadPath -Raw | ConvertFrom-Json -Depth 100
        } else {
            $null
        }

        return [PSCustomObject]@{
            ExitCode = $process.ExitCode
            StdOut   = if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { Get-Content -LiteralPath $stdoutPath -Raw } else { '' }
            StdErr   = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
            Warnings = if ($payload -and $payload.PSObject.Properties['Warnings']) { @($payload.Warnings) } else { @() }
            Envelope = if ($payload -and $payload.PSObject.Properties['Envelope']) { $payload.Envelope } else { $null }
        }
    } finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
