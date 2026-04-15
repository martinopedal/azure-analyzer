#Requires -Version 7.0
[CmdletBinding()]
param(
    [string] $InputPath = (Join-Path $PSScriptRoot '..' 'output' 'results.json'),
    [string] $OutputPath = (Join-Path $PSScriptRoot '..' 'output' 'triage.json')
)
Set-StrictMode -Version Latest
try { $v = & python3 --version 2>&1; if ($LASTEXITCODE -ne 0) { $v = & python --version 2>&1 } } catch { try { $v = & python --version 2>&1 } catch { Write-Warning 'AI Triage: Python not found'; return $null } }
if (-not ($v -match 'Python (\d+)\.(\d+)') -or [int]$Matches[1] -lt 3 -or [int]$Matches[2] -lt 10) { Write-Warning 'AI Triage: Python 3.10+ required'; return $null }
$py = if ($v -match 'python3') { 'python3' } else { 'python' }
try { & $py -c 'import copilot' 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { throw } } catch { Write-Warning 'AI Triage: pip install github-copilot-sdk'; return $null }
$tk = $env:COPILOT_GITHUB_TOKEN; if (-not $tk) { $tk = $env:GH_TOKEN }; if (-not $tk) { $tk = $env:GITHUB_TOKEN }
if (-not $tk) { Write-Warning 'AI Triage: No token'; return $null }
if ($tk.StartsWith('ghs_')) { Write-Warning 'AI Triage: ghs_ unsupported'; return $null }
if (-not (Test-Path $InputPath)) { Write-Warning "AI Triage: $InputPath not found"; return $null }
$sp = Join-Path $PSScriptRoot 'Invoke-CopilotTriage.py'
if (-not (Test-Path $sp)) { Write-Warning 'AI Triage: Python script missing'; return $null }
Write-Host 'Running AI triage...' -ForegroundColor Magenta
try {
    & $py $sp --input $InputPath --output $OutputPath 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) { Write-Warning "AI Triage: exit code $LASTEXITCODE"; return $null }
    if (-not (Test-Path $OutputPath)) { Write-Warning 'AI Triage: triage.json not created'; return $null }
    return (Get-Content $OutputPath -Raw | ConvertFrom-Json -ErrorAction Stop)
} catch { Write-Warning "AI Triage: $_"; return $null }
