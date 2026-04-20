#Requires -Version 7.4
<#
.SYNOPSIS
    Generate a single-page executive dashboard (Phase 11 / #97) from current run +
    historical snapshots.

.DESCRIPTION
    Thin wrapper around modules/shared/ExecDashboardRender.ps1 (issue #210).
    The HTML/CSS/data composition was extracted into that shared module so that
    BOTH the standalone dashboard.html (this script's output) and the Summary tab
    embedded in report.html can render the same content from one source of truth.

    Reads:
      - output/results.json            (current run findings)
      - output/history/                (prior snapshots written by RunHistory.ps1)
      - output/entities.json           (optional v3 entity store, for subscription view)
      - tools/framework-mappings.json  (WAF pillar coverage + framework gap)

    Writes a single self-contained dashboard.html (no CDN, inline CSS + inline SVG
    sparklines).

.PARAMETER InputPath
    Current run results.json. Defaults to .\output\results.json.

.PARAMETER OutputPath
    Path for dashboard.html. Defaults to .\output\dashboard.html.

.PARAMETER HistoryPath
    Override for the history root. Defaults to <InputPath dir>\history.

.PARAMETER EntitiesPath
    Optional v3 entities.json. Defaults to <InputPath dir>\entities.json.

.PARAMETER ToolStatusPath
    Optional tool-status.json. Defaults to <InputPath dir>\tool-status.json.
#>
[CmdletBinding()]
param (
    [string] $InputPath      = (Join-Path $PSScriptRoot 'output' 'results.json'),
    [string] $OutputPath     = (Join-Path $PSScriptRoot 'output' 'dashboard.html'),
    [string] $HistoryPath    = '',
    [string] $EntitiesPath   = '',
    [string] $ToolStatusPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'modules' 'shared' 'ExecDashboardRender.ps1')

$html = Get-ExecDashboardHtml `
    -InputPath      $InputPath `
    -HistoryPath    $HistoryPath `
    -EntitiesPath   $EntitiesPath `
    -ToolStatusPath $ToolStatusPath

Set-Content -Path $OutputPath -Value $html -Encoding UTF8
Write-Host "Wrote dashboard: $OutputPath" -ForegroundColor Green
