#Requires -Version 7.4

Set-StrictMode -Version Latest

if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    $sanitizePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Sanitize.ps1'
    if (Test-Path $sanitizePath) { . $sanitizePath }
}
if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param([string]$Text) return $Text }
}

function Test-PreflightNonInteractive {
    [CmdletBinding()]
    param(
        [switch] $NonInteractive
    )

    if ($NonInteractive) { return $true }

    $ci = [string]$env:CI
    if ($ci -imatch '^(true|1|yes|on)$') { return $true }

    try {
        if (-not [Environment]::UserInteractive) { return $true }
    } catch {
        Write-Verbose ("Test-NonInteractive: [Environment]::UserInteractive probe failed; defaulting to interactive. Reason: {0}" -f $_.Exception.Message)
    }

    try {
        if ([Console]::IsInputRedirected) { return $true }
    } catch {
        Write-Verbose ("Test-NonInteractive: [Console]::IsInputRedirected probe failed; defaulting to interactive. Reason: {0}" -f $_.Exception.Message)
    }

    return $false
}

function Test-PreflightConditional {
    [CmdletBinding()]
    param(
        [object] $Conditional,
        [hashtable] $KnownValues
    )

    if ($null -eq $Conditional) { return $true }
    if ($Conditional -isnot [System.Collections.IDictionary] -and -not $Conditional.PSObject) { return $true }
    if (-not $Conditional.PSObject.Properties['param']) { return $true }

    $paramName = [string]$Conditional.param
    if ([string]::IsNullOrWhiteSpace($paramName)) { return $true }
    $current = if ($KnownValues.ContainsKey($paramName)) { [string]$KnownValues[$paramName] } else { '' }

    if ($Conditional.PSObject.Properties['equals']) {
        return ($current -ieq [string]$Conditional.equals)
    }
    if ($Conditional.PSObject.Properties['notEquals']) {
        return ($current -ine [string]$Conditional.notEquals)
    }

    return $true
}

function Test-IsSensitiveInputName {
    [CmdletBinding()]
    param([string] $Name)
    return ($Name -match '(?i)(token|pat|secret|password|credential|key)')
}

function Test-PreflightValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Value,
        [string] $Type = 'string',
        [string] $Validator,
        [string[]] $EnumValues
    )

    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }

    $ok = $true
    switch (($Type ?? 'string').ToLowerInvariant()) {
        'guid' {
            $guid = [Guid]::Empty
            $ok = [Guid]::TryParse($text, [ref]$guid)
        }
        'url' {
            $uri = $null
            $ok = [Uri]::TryCreate($text, [UriKind]::Absolute, [ref]$uri)
        }
        'bool' {
            $ok = $text -match '^(?i:true|false|1|0|yes|no|on|off)$'
        }
        'enum' {
            if ($EnumValues -and $EnumValues.Count -gt 0) {
                $ok = $text -in $EnumValues
            } else {
                $ok = $true
            }
        }
        default {
            $ok = $true
        }
    }

    if (-not $ok) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($Validator)) {
        return ($text -match $Validator)
    }
    return $true
}

function Get-RequiredInputs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $Tools,

        [hashtable] $CliValues = @{},

        [switch] $NonInteractive
    )

    $isNonInteractive = Test-PreflightNonInteractive -NonInteractive:$NonInteractive
    $requirements = [System.Collections.Specialized.OrderedDictionary]::new()

    # Pre-resolve a merged value map (CLI > env) across every candidate input across every
    # tool, regardless of whether a `conditional` would gate it. This lets
    # Test-PreflightConditional honor values supplied via env vars - not just CLI - so a
    # downstream input is not falsely flagged as required when its prerequisite is satisfied
    # by an env var. CLI > env > prompt precedence is preserved (prompt happens later, only
    # for inputs that survive the conditional pass).
    $knownValues = @{}
    foreach ($k in $CliValues.Keys) {
        if (-not [string]::IsNullOrWhiteSpace([string]$CliValues[$k])) {
            $knownValues[$k] = $CliValues[$k]
        }
    }
    foreach ($tool in @($Tools)) {
        $allInputs = if ($tool.PSObject.Properties['required_inputs']) { @($tool.required_inputs) } else { @() }
        foreach ($inputDef in $allInputs) {
            if ($null -eq $inputDef) { continue }
            $nameProp = $inputDef.PSObject.Properties['name']
            $name = if ($nameProp) { [string]$nameProp.Value } else { '' }
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($knownValues.ContainsKey($name)) { continue }
            $envName = if ($inputDef.PSObject.Properties['envVar']) { [string]$inputDef.envVar } else { '' }
            if (-not [string]::IsNullOrWhiteSpace($envName)) {
                $envValue = [Environment]::GetEnvironmentVariable($envName)
                if (-not [string]::IsNullOrWhiteSpace([string]$envValue)) {
                    $knownValues[$name] = $envValue
                }
            }
        }
    }

    foreach ($tool in @($Tools)) {
        $toolRequiredInputs = if ($tool.PSObject.Properties['required_inputs']) { @($tool.required_inputs) } else { @() }
        foreach ($inputDef in $toolRequiredInputs) {
            if ($null -eq $inputDef) { continue }
            $nameProp = $inputDef.PSObject.Properties['name']
            $name = if ($nameProp) { [string]$nameProp.Value } else { '' }
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $conditional = if ($inputDef.PSObject.Properties['conditional']) { $inputDef.conditional } else { $null }
            if (-not (Test-PreflightConditional -Conditional $conditional -KnownValues $knownValues)) { continue }
            if (-not $requirements.Contains($name)) {
                $type = if ($inputDef.PSObject.Properties['type']) { [string]$inputDef.type } else { 'string' }
                $prompt = if ($inputDef.PSObject.Properties['prompt']) { [string]$inputDef.prompt } else { '' }
                $envVar = if ($inputDef.PSObject.Properties['envVar']) { [string]$inputDef.envVar } else { '' }
                $example = if ($inputDef.PSObject.Properties['example']) { [string]$inputDef.example } else { '' }
                $validator = if ($inputDef.PSObject.Properties['validator']) { [string]$inputDef.validator } else { '' }
                $enumValues = if ($inputDef.PSObject.Properties['enumValues']) { @($inputDef.enumValues) } else { @() }
                $requirements[$name] = [PSCustomObject]@{
                    Name      = $name
                    Type      = $type
                    Prompt    = $prompt
                    EnvVar    = $envVar
                    Example   = $example
                    Validator = $validator
                    EnumValues = $enumValues
                    Sensitive = (Test-IsSensitiveInputName -Name $name)
                }
            }
        }
    }

    $resolved = @{}
    $missing  = [System.Collections.Generic.List[object]]::new()

    foreach ($entry in $requirements.Values) {
        $name = $entry.Name
        $value = $null

        if ($CliValues.ContainsKey($name) -and -not [string]::IsNullOrWhiteSpace([string]$CliValues[$name])) {
            $value = $CliValues[$name]
        }

        if ([string]::IsNullOrWhiteSpace([string]$value) -and -not [string]::IsNullOrWhiteSpace($entry.EnvVar)) {
            $envValue = [Environment]::GetEnvironmentVariable($entry.EnvVar)
            if (-not [string]::IsNullOrWhiteSpace([string]$envValue)) {
                $value = $envValue
            }
        }

        # Prompt only when interactive, unresolved, and not a sensitive secret-like input.
        if ((-not $isNonInteractive) -and
            [string]::IsNullOrWhiteSpace([string]$value) -and
            -not $entry.Sensitive) {
            $prompt = if ([string]::IsNullOrWhiteSpace($entry.Prompt)) { "Enter $name" } else { $entry.Prompt }
            if (-not [string]::IsNullOrWhiteSpace($entry.Example)) {
                $prompt = "$prompt (example: $($entry.Example))"
            }
            $value = Read-Host -Prompt $prompt
        }

        if (Test-PreflightValue -Value $value -Type $entry.Type -Validator $entry.Validator -EnumValues $entry.EnumValues) {
            $resolved[$name] = [string]$value
            continue
        }

        $missing.Add($entry) | Out-Null
    }

    if ($missing.Count -gt 0) {
        $details = foreach ($item in $missing) {
            $displayName = if ([string]::IsNullOrWhiteSpace([string]$item.Name)) { '<unknown>' } else { [string]$item.Name }
            $parts = @($displayName)
            if (-not [string]::IsNullOrWhiteSpace($item.EnvVar)) { $parts += "env:$($item.EnvVar)" }
            if (-not [string]::IsNullOrWhiteSpace($item.Example)) { $parts += "example:$($item.Example)" }
            if ($item.Sensitive) { $parts += 'prompting-disabled(use-cli-or-env)' }
            $parts -join ' '
        }
        throw (Remove-Credentials -Text "Unresolved required inputs. Provide via CLI parameters, environment variables, or run without -NonInteractive: $($details -join '; ')")
    }

    return $resolved
}
