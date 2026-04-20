#Requires -Version 7.4
<#
.SYNOPSIS
    Per-wrapper opt-in elevated RBAC tier mechanism (vNEXT v1.2.0, #234).

.DESCRIPTION
    azure-analyzer wrappers default to a Reader-only RBAC tier. A small
    number of advanced inspections (e.g. Karpenter Provisioner discovery
    inside the AKS data plane) need cluster-data-plane reads that the ARM
    Reader role does not expose. This module implements an explicit,
    off-by-default opt-in:

      * Tier 'Reader'      - the default. Covers all ARM/Graph reads that
                             the standard Reader / per-domain read-only
                             roles already grant.
      * Tier 'ClusterUser' - opt-in. Covers the additional kubeconfig
                             retrieval performed by the Karpenter
                             inspection branch (Azure Kubernetes Service
                             Cluster User Role at the AKS cluster scope).

    The opt-in is per-wrapper invocation, NOT orchestrator-wide. A wrapper
    that exposes -EnableElevatedRbac calls Set-RbacTier 'ClusterUser' at
    the very top of its body and Reset-RbacTier in finally{}. The state
    is held in a script-scope variable on this module, so unrelated
    wrappers running in the same process default back to 'Reader'.

    The per-wrapper scoping decision is documented in
    .squad/decisions/inbox/atlas-issue-234-complete-* and in
    docs/consumer/permissions/aks-karpenter-cost.md.

.NOTES
    All assertion failures throw an error with the [InsufficientRbac]
    prefix and an actionable remediation that points the consumer at the
    -EnableElevatedRbac flag on the calling wrapper.
#>
[CmdletBinding()]
param ()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RbacTierAllowed = @('Reader', 'ClusterUser')
$script:RbacTierCurrent = 'Reader'

function Get-RbacTier {
    <#
    .SYNOPSIS
        Return the currently active RBAC tier ('Reader' or 'ClusterUser').
    #>
    [CmdletBinding()]
    param ()
    return $script:RbacTierCurrent
}

function Set-RbacTier {
    <#
    .SYNOPSIS
        Set the active RBAC tier for the current wrapper invocation.
    .PARAMETER Tier
        One of 'Reader' or 'ClusterUser'.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('Reader', 'ClusterUser')]
        [string] $Tier
    )
    $script:RbacTierCurrent = $Tier
    Write-Verbose ("[rbactier] active tier set to '{0}'" -f $Tier)
}

function Reset-RbacTier {
    <#
    .SYNOPSIS
        Restore the default Reader tier. Wrappers MUST call this in
        finally{} after they Set-RbacTier 'ClusterUser'.
    #>
    [CmdletBinding()]
    param ()
    $script:RbacTierCurrent = 'Reader'
}

function Test-RbacTierSatisfies {
    <#
    .SYNOPSIS
        Return $true when the active tier is at or above the required tier.
    .PARAMETER Required
        One of 'Reader' or 'ClusterUser'.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('Reader', 'ClusterUser')]
        [string] $Required
    )

    $rank = @{ Reader = 0; ClusterUser = 1 }
    return $rank[$script:RbacTierCurrent] -ge $rank[$Required]
}

function Assert-RbacTier {
    <#
    .SYNOPSIS
        Throw [InsufficientRbac] when the active tier is below the required tier.
    .PARAMETER Required
        One of 'Reader' or 'ClusterUser'.
    .PARAMETER OptInFlag
        Name of the wrapper switch that enables the elevated tier
        (defaults to '-EnableElevatedRbac'). Surfaced in the remediation
        text so the consumer knows exactly which flag to pass.
    .PARAMETER Capability
        Short human-readable name of the gated capability (e.g.
        'Karpenter Provisioner inspection'). Surfaced in the error.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('Reader', 'ClusterUser')]
        [string] $Required,

        [string] $OptInFlag = '-EnableElevatedRbac',
        [string] $Capability = 'this elevated capability'
    )

    if (Test-RbacTierSatisfies -Required $Required) { return }

    $remediation = "Pass $OptInFlag to the wrapper to opt in to the '$Required' tier (Azure Kubernetes Service Cluster User Role at the AKS cluster scope). The opt-in is OFF by default; see docs/consumer/permissions/aks-karpenter-cost.md."
    $message = "[InsufficientRbac] $Capability requires RBAC tier '$Required' but the active tier is '$script:RbacTierCurrent'. $remediation"
    throw $message
}
