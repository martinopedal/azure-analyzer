#Requires -Version 7.4
<#
.SYNOPSIS
    Checkpoint helpers for tool execution.
.DESCRIPTION
    Saves, loads, and removes per-tool checkpoint files to support resume.
    Checkpoints are keyed by tool name and scope-specific identifiers.
#>
[CmdletBinding()]
param ()

Set-StrictMode -Version Latest

function ConvertTo-SafeCheckpointComponent {
    param (
        [AllowNull()]
        [string] $Value
    )

    if ($null -eq $Value) { return $null }
    return ($Value -replace '[/\\]', '_' -replace '\.\.', '_')
}

function Get-CheckpointKey {
    <#
    .SYNOPSIS
        Builds a scope-aware checkpoint key.
    .PARAMETER ScopeType
        The scope classification for the tool.
    .PARAMETER SubscriptionId
        Azure subscription ID for subscription-scoped tools.
    .PARAMETER ManagementGroupId
        Management group ID for MG-scoped tools.
    .PARAMETER TenantId
        Tenant ID for tenant-scoped tools.
    .PARAMETER RepoSlug
        Repository slug in the form owner-repo.
    .PARAMETER AdoOrg
        Azure DevOps organization name.
    .PARAMETER AdoProject
        Azure DevOps project name.
.PARAMETER CorrelationId
    Reserved for future correlation identifiers; identity checkpoints use
    the fixed key "identity-correlator" by default.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('Subscription', 'ManagementGroup', 'Tenant', 'Repository', 'ADO', 'Identity')]
        [string] $ScopeType,

        [string] $SubscriptionId,
        [string] $ManagementGroupId,
        [string] $TenantId,
        [string] $RepoSlug,
        [string] $AdoOrg,
        [string] $AdoProject,
        [string] $CorrelationId = 'identity-correlator'
    )

    switch ($ScopeType) {
        'Subscription' {
            if (-not $SubscriptionId) { throw "SubscriptionId is required for subscription-scoped checkpoints." }
            return (ConvertTo-SafeCheckpointComponent -Value $SubscriptionId)
        }
        'ManagementGroup' {
            if (-not $ManagementGroupId) { throw "ManagementGroupId is required for management-group checkpoints." }
            return (ConvertTo-SafeCheckpointComponent -Value "mg-$ManagementGroupId")
        }
        'Tenant' {
            if (-not $TenantId) { throw "TenantId is required for tenant-scoped checkpoints." }
            return (ConvertTo-SafeCheckpointComponent -Value "tenant-$TenantId")
        }
        'Repository' {
            if (-not $RepoSlug) { throw "RepoSlug is required for repository-scoped checkpoints." }
            return (ConvertTo-SafeCheckpointComponent -Value "repo-$RepoSlug")
        }
        'ADO' {
            if (-not $AdoOrg -or -not $AdoProject) { throw "AdoOrg and AdoProject are required for ADO checkpoints." }
            return (ConvertTo-SafeCheckpointComponent -Value "ado-$AdoOrg-$AdoProject")
        }
        'Identity' {
            return (ConvertTo-SafeCheckpointComponent -Value ($CorrelationId ?? 'identity-correlator'))
        }
    }
}

function Get-CheckpointPath {
    <#
    .SYNOPSIS
        Resolves the checkpoint file path for a tool and scope key.
    .PARAMETER CheckpointDir
        Directory where checkpoint files are stored.
    .PARAMETER Tool
        Tool name.
    .PARAMETER ScopeKey
        Scope-specific checkpoint key.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $CheckpointDir,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Tool,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ScopeKey
    )

    $resolvedCheckpointDir = [System.IO.Path]::GetFullPath($CheckpointDir)
    $sanitizedTool = ConvertTo-SafeCheckpointComponent -Value $Tool
    $sanitizedScopeKey = ConvertTo-SafeCheckpointComponent -Value $ScopeKey
    $resolvedPath = [System.IO.Path]::GetFullPath((Join-Path $resolvedCheckpointDir "$sanitizedTool-$sanitizedScopeKey.json"))

    $checkpointRoot = if ($resolvedCheckpointDir.EndsWith('\')) { $resolvedCheckpointDir } else { "$resolvedCheckpointDir\" }
    if (-not $resolvedPath.StartsWith($checkpointRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Checkpoint path resolution escaped checkpoint directory: $resolvedPath"
    }

    return $resolvedPath
}

function Save-Checkpoint {
    <#
    .SYNOPSIS
        Writes tool results to a checkpoint file.
    .PARAMETER CheckpointDir
        Directory where checkpoint files are stored.
    .PARAMETER Tool
        Tool name.
    .PARAMETER ScopeType
        Scope classification for the tool.
    .PARAMETER Result
        Tool result to serialize.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $CheckpointDir,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Tool,

        [Parameter(Mandatory)]
        [ValidateSet('Subscription', 'ManagementGroup', 'Tenant', 'Repository', 'ADO', 'Identity')]
        [string] $ScopeType,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [PSCustomObject] $Result,

        [string] $SubscriptionId,
        [string] $ManagementGroupId,
        [string] $TenantId,
        [string] $RepoSlug,
        [string] $AdoOrg,
        [string] $AdoProject,
        [string] $CorrelationId = 'identity-correlator'
    )

    if (-not (Test-Path $CheckpointDir)) {
        $null = New-Item -ItemType Directory -Path $CheckpointDir -Force
    }

    $scopeKey = Get-CheckpointKey -ScopeType $ScopeType -SubscriptionId $SubscriptionId `
        -ManagementGroupId $ManagementGroupId -TenantId $TenantId -RepoSlug $RepoSlug `
        -AdoOrg $AdoOrg -AdoProject $AdoProject -CorrelationId $CorrelationId

    $path = Get-CheckpointPath -CheckpointDir $CheckpointDir -Tool $Tool -ScopeKey $scopeKey
    $json = $Result | ConvertTo-Json -Depth 50
    $tempPath = "$path.tmp-$([Guid]::NewGuid().ToString('N'))"
    Set-Content -Path $tempPath -Value $json -Encoding utf8
    Move-Item -Path $tempPath -Destination $path -Force
    return $path
}

function Get-Checkpoint {
    <#
    .SYNOPSIS
        Loads a checkpoint file if present.
    .PARAMETER CheckpointDir
        Directory where checkpoint files are stored.
    .PARAMETER Tool
        Tool name.
    .PARAMETER ScopeType
        Scope classification for the tool.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $CheckpointDir,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Tool,

        [Parameter(Mandatory)]
        [ValidateSet('Subscription', 'ManagementGroup', 'Tenant', 'Repository', 'ADO', 'Identity')]
        [string] $ScopeType,

        [string] $SubscriptionId,
        [string] $ManagementGroupId,
        [string] $TenantId,
        [string] $RepoSlug,
        [string] $AdoOrg,
        [string] $AdoProject,
        [string] $CorrelationId = 'identity-correlator'
    )

    $scopeKey = Get-CheckpointKey -ScopeType $ScopeType -SubscriptionId $SubscriptionId `
        -ManagementGroupId $ManagementGroupId -TenantId $TenantId -RepoSlug $RepoSlug `
        -AdoOrg $AdoOrg -AdoProject $AdoProject -CorrelationId $CorrelationId

    $path = Get-CheckpointPath -CheckpointDir $CheckpointDir -Tool $Tool -ScopeKey $scopeKey
    if (-not (Test-Path $path)) {
        return $null
    }

    try {
        return (Get-Content -Raw $path | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        Write-Warning "Checkpoint file '$path' is corrupt or unreadable. Treating as cache miss. $_"
        return $null
    }
}

function Remove-Checkpoint {
    <#
    .SYNOPSIS
        Deletes a checkpoint file after successful completion.
    .PARAMETER CheckpointDir
        Directory where checkpoint files are stored.
    .PARAMETER Tool
        Tool name.
    .PARAMETER ScopeType
        Scope classification for the tool.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $CheckpointDir,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Tool,

        [Parameter(Mandatory)]
        [ValidateSet('Subscription', 'ManagementGroup', 'Tenant', 'Repository', 'ADO', 'Identity')]
        [string] $ScopeType,

        [string] $SubscriptionId,
        [string] $ManagementGroupId,
        [string] $TenantId,
        [string] $RepoSlug,
        [string] $AdoOrg,
        [string] $AdoProject,
        [string] $CorrelationId = 'identity-correlator'
    )

    $scopeKey = Get-CheckpointKey -ScopeType $ScopeType -SubscriptionId $SubscriptionId `
        -ManagementGroupId $ManagementGroupId -TenantId $TenantId -RepoSlug $RepoSlug `
        -AdoOrg $AdoOrg -AdoProject $AdoProject -CorrelationId $CorrelationId

    $path = Get-CheckpointPath -CheckpointDir $CheckpointDir -Tool $Tool -ScopeKey $scopeKey
    if (Test-Path $path) {
        Remove-Item -Path $path -Force
        return $true
    }

    return $false
}
