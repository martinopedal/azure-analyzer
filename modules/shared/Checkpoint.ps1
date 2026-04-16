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
    the fixed key "correlation".
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
        [string] $CorrelationId = 'correlation'
    )

    switch ($ScopeType) {
        'Subscription' {
            if (-not $SubscriptionId) { throw "SubscriptionId is required for subscription-scoped checkpoints." }
            return $SubscriptionId
        }
        'ManagementGroup' {
            if (-not $ManagementGroupId) { throw "ManagementGroupId is required for management-group checkpoints." }
            return "mg-$ManagementGroupId"
        }
        'Tenant' {
            if (-not $TenantId) { throw "TenantId is required for tenant-scoped checkpoints." }
            return "tenant-$TenantId"
        }
        'Repository' {
            if (-not $RepoSlug) { throw "RepoSlug is required for repository-scoped checkpoints." }
            return "repo-$RepoSlug"
        }
        'ADO' {
            if (-not $AdoOrg -or -not $AdoProject) { throw "AdoOrg and AdoProject are required for ADO checkpoints." }
            return "ado-$AdoOrg-$AdoProject"
        }
        'Identity' {
            return 'correlation'
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

    return (Join-Path $CheckpointDir "$Tool-$ScopeKey.json")
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
        [string] $CorrelationId = 'correlation'
    )

    if (-not (Test-Path $CheckpointDir)) {
        $null = New-Item -ItemType Directory -Path $CheckpointDir -Force
    }

    $scopeKey = Get-CheckpointKey -ScopeType $ScopeType -SubscriptionId $SubscriptionId `
        -ManagementGroupId $ManagementGroupId -TenantId $TenantId -RepoSlug $RepoSlug `
        -AdoOrg $AdoOrg -AdoProject $AdoProject -CorrelationId $CorrelationId

    $path = Get-CheckpointPath -CheckpointDir $CheckpointDir -Tool $Tool -ScopeKey $scopeKey
    $json = $Result | ConvertTo-Json -Depth 50
    Set-Content -Path $path -Value $json -Encoding utf8
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
        [string] $CorrelationId = 'correlation'
    )

    $scopeKey = Get-CheckpointKey -ScopeType $ScopeType -SubscriptionId $SubscriptionId `
        -ManagementGroupId $ManagementGroupId -TenantId $TenantId -RepoSlug $RepoSlug `
        -AdoOrg $AdoOrg -AdoProject $AdoProject -CorrelationId $CorrelationId

    $path = Get-CheckpointPath -CheckpointDir $CheckpointDir -Tool $Tool -ScopeKey $scopeKey
    if (-not (Test-Path $path)) {
        return $null
    }

    return (Get-Content -Raw $path | ConvertFrom-Json -ErrorAction Stop)
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
        [string] $CorrelationId = 'correlation'
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
