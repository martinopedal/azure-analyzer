#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    CLI timeout helper for wrapper scripts.
.DESCRIPTION
    Provides Invoke-WithTimeout for wrapping external CLI invocations with a
    hard timeout. When the command resolves to a real executable (Application),
    uses System.Diagnostics.Process for reliable timeout/kill semantics.
    When the command is a PowerShell function (e.g. test mock), falls back to
    the call operator & so that Pester mocks work transparently.

    Returns [PSCustomObject]@{ ExitCode; Output; Stdout; Stderr }.
    On timeout: ExitCode = -1, Output = "Timed out after N seconds".
#>

# Always define the smart version that handles both real executables and test mocks.
# This overrides any previously-loaded Process-only version from Installer.ps1
# which cannot invoke PowerShell function mocks used by Pester tests.
function Invoke-WithTimeout {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory)][string]   $Command,
            [Parameter(Mandatory)][string[]] $Arguments,
            [int] $TimeoutSec = 300
        )

        $sanitize = if (Get-Command Remove-Credentials -ErrorAction SilentlyContinue) {
            ${function:Remove-Credentials}
        } else {
            { param([string]$Text) $Text }
        }

        $cmdInfo = Get-Command $Command -ErrorAction SilentlyContinue
        $cmdType = if ($cmdInfo -and $cmdInfo.PSObject.Properties['CommandType']) { $cmdInfo.CommandType } else { $null }

        # Real executable — use System.Diagnostics.Process with hard timeout
        if ($cmdType -eq 'Application') {
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName  = $cmdInfo.Source
            foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.UseShellExecute = $false

            $proc = [System.Diagnostics.Process]::new()
            $proc.StartInfo = $psi
            $null = $proc.Start()

            $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
            $stderrTask = $proc.StandardError.ReadToEndAsync()

            if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
                try { $proc.Kill($true) } catch {
                    Write-Verbose ("Invoke-WithTimeout: Kill after timeout failed: {0}" -f $_.Exception.Message)
                }
                return [PSCustomObject]@{
                    ExitCode = -1
                    Output   = "Timed out after $TimeoutSec seconds"
                    Stdout   = ''
                    Stderr   = "Timed out after $TimeoutSec seconds"
                }
            }

            $stdout  = $stdoutTask.Result
            $stderr  = $stderrTask.Result
            $combined = (& $sanitize (($stdout + "`n" + $stderr).Trim()))
            return [PSCustomObject]@{
                ExitCode = $proc.ExitCode
                Output   = $combined
                Stdout   = (& $sanitize $stdout)
                Stderr   = (& $sanitize $stderr)
            }
        }

        # PowerShell function/alias/cmdlet (test mocks) — call operator fallback
        $output = & $Command @Arguments 2>&1 | Out-String
        $lastExit = if (Test-Path variable:LASTEXITCODE) { $LASTEXITCODE } else { 0 }
        return [PSCustomObject]@{
            ExitCode = $lastExit
            Output   = $output.Trim()
            Stdout   = $output.Trim()
            Stderr   = ''
        }
    }
