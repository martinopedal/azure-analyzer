#Requires -Version 7.0
<#
.SYNOPSIS
    Cost Management API checks — budget hygiene and cost governance.
.DESCRIPTION
    Checks for:
    - Budget existence (at least one budget configured)
    - Budget alert notification thresholds (>=80%)
    - Cost anomaly alert rules (InsightAlert scheduled actions)
    - Azure Advisor high-impact cost recommendations (unactioned)
.PARAMETER SubscriptionId
    Azure subscription ID to assess.
.PARAMETER AccessToken
    Optional. Bearer token for the management.azure.com endpoint.
    Falls back to Get-AzAccessToken if not supplied.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string] $SubscriptionId,
    [string] $AccessToken
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$findings = [System.Collections.Generic.List[PSCustomObject]]::new()

# ── helper: resolve auth token ───────────────────────────────────────────────
function Get-Token {
    param ([string]$Supplied)
    if (-not [string]::IsNullOrEmpty($Supplied)) { return $Supplied }
    try {
        $tok = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/' -ErrorAction Stop
        return $tok.Token
    } catch {
        Write-Warning "Invoke-CostManagementApi: Could not obtain access token: $_"
        return $null
    }
}

# ── helper: invoke ARM REST call ─────────────────────────────────────────────
function Invoke-ArmApi {
    param (
        [string] $Token,
        [string] $Uri
    )
    try {
        $response = Invoke-RestMethod -Uri $Uri `
            -Method Get `
            -Headers @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' } `
            -ErrorAction SilentlyContinue
        return $response
    } catch {
        Write-Warning "Invoke-CostManagementApi: API call failed for $Uri — $_"
        return $null
    }
}

$token = Get-Token -Supplied $AccessToken
if ($null -eq $token) {
    Write-Warning 'Invoke-CostManagementApi: No auth token available — returning empty findings.'
    return [PSCustomObject]@{ Source = 'cost-management'; Findings = $findings.ToArray() }
}

$baseUrl = 'https://management.azure.com'
$subPath = "subscriptions/$SubscriptionId"

# ── Check 1: Budget existence ─────────────────────────────────────────────────
try {
    $budgetsUri = "$baseUrl/$subPath/providers/Microsoft.Consumption/budgets?api-version=2023-11-01"
    $budgetsResp = Invoke-ArmApi -Token $token -Uri $budgetsUri
    $budgets = @()
    if ($null -ne $budgetsResp -and $null -ne $budgetsResp.PSObject.Properties['value']) {
        $budgets = @($budgetsResp.value)
    }

    $findings.Add([PSCustomObject]@{
        Id          = [guid]::NewGuid().ToString()
        Source      = 'cost-management'
        Category    = 'Cost'
        Title       = 'Budget configured for subscription'
        Severity    = 'High'
        Compliant   = ($budgets.Count -gt 0)
        Detail      = if ($budgets.Count -gt 0) {
                          "$($budgets.Count) budget(s) found on subscription $SubscriptionId"
                      } else {
                          "No budgets found on subscription $SubscriptionId. Configure at least one budget to track spending."
                      }
        Remediation = 'https://learn.microsoft.com/azure/cost-management-billing/costs/tutorial-acm-create-budgets'
    })
} catch {
    Write-Warning "Invoke-CostManagementApi: Budget existence check failed — $_"
}

# ── Check 2: Budget alert notification thresholds ─────────────────────────────
try {
    $budgetsUri = "$baseUrl/$subPath/providers/Microsoft.Consumption/budgets?api-version=2023-11-01"
    $budgetsResp = Invoke-ArmApi -Token $token -Uri $budgetsUri
    $budgets = @()
    if ($null -ne $budgetsResp -and $null -ne $budgetsResp.PSObject.Properties['value']) {
        $budgets = @($budgetsResp.value)
    }

    $alertedBudgets = @($budgets | Where-Object {
        $props = $_.PSObject.Properties['properties']?.Value
        if ($null -eq $props) { return $false }
        $notifications = $props.PSObject.Properties['notifications']?.Value
        if ($null -eq $notifications) { return $false }
        # notifications is a hashtable/object keyed by name; check any threshold >= 80
        $notifProps = $notifications.PSObject.Properties
        if ($null -eq $notifProps) { return $false }
        $hasThreshold = $notifProps | Where-Object {
            $threshold = $_.Value.PSObject.Properties['threshold']?.Value
            $null -ne $threshold -and [double]$threshold -ge 80
        }
        return ($null -ne $hasThreshold -and @($hasThreshold).Count -gt 0)
    })

    $findings.Add([PSCustomObject]@{
        Id          = [guid]::NewGuid().ToString()
        Source      = 'cost-management'
        Category    = 'Cost'
        Title       = 'Budget alert notifications configured at >=80% threshold'
        Severity    = 'Medium'
        Compliant   = ($alertedBudgets.Count -gt 0)
        Detail      = if ($alertedBudgets.Count -gt 0) {
                          "$($alertedBudgets.Count) budget(s) have alert notifications at >=80% threshold"
                      } else {
                          "No budgets with notification thresholds >=80% found. Add alert notifications to budgets so spending spikes trigger alerts."
                      }
        Remediation = 'https://learn.microsoft.com/azure/cost-management-billing/costs/tutorial-acm-create-budgets#configure-notifications'
    })
} catch {
    Write-Warning "Invoke-CostManagementApi: Budget alert threshold check failed — $_"
}

# ── Check 3: Cost anomaly alert rules ─────────────────────────────────────────
try {
    $scheduledActionsUri = "$baseUrl/$subPath/providers/Microsoft.CostManagement/scheduledActions?api-version=2023-11-01&`$filter=kind eq 'InsightAlert'"
    $actionsResp = Invoke-ArmApi -Token $token -Uri $scheduledActionsUri
    $anomalyAlerts = @()
    if ($null -ne $actionsResp -and $null -ne $actionsResp.PSObject.Properties['value']) {
        $anomalyAlerts = @($actionsResp.value)
    }

    $findings.Add([PSCustomObject]@{
        Id          = [guid]::NewGuid().ToString()
        Source      = 'cost-management'
        Category    = 'Cost'
        Title       = 'Cost anomaly alert rules configured'
        Severity    = 'Medium'
        Compliant   = ($anomalyAlerts.Count -gt 0)
        Detail      = if ($anomalyAlerts.Count -gt 0) {
                          "$($anomalyAlerts.Count) anomaly alert rule(s) (InsightAlert) found on subscription $SubscriptionId"
                      } else {
                          "No cost anomaly alert rules (InsightAlert) found on subscription $SubscriptionId. Anomaly alerts proactively detect unexpected spending."
                      }
        Remediation = 'https://learn.microsoft.com/azure/cost-management-billing/understand/analyze-unexpected-charges#create-an-anomaly-alert'
    })
} catch {
    Write-Warning "Invoke-CostManagementApi: Anomaly alert check failed — $_"
}

# ── Check 4: Azure Advisor high-impact cost recommendations ───────────────────
try {
    $advisorUri = "$baseUrl/$subPath/providers/Microsoft.Advisor/recommendations?api-version=2023-01-01&`$filter=Category eq 'Cost' and Impact eq 'High'"
    $advisorResp = Invoke-ArmApi -Token $token -Uri $advisorUri
    $highImpactRecs = @()
    if ($null -ne $advisorResp -and $null -ne $advisorResp.PSObject.Properties['value']) {
        $highImpactRecs = @($advisorResp.value)
    }

    $findings.Add([PSCustomObject]@{
        Id          = [guid]::NewGuid().ToString()
        Source      = 'cost-management'
        Category    = 'Cost'
        Title       = 'No unactioned high-impact Advisor cost recommendations'
        Severity    = 'High'
        Compliant   = ($highImpactRecs.Count -eq 0)
        Detail      = if ($highImpactRecs.Count -eq 0) {
                          "No unactioned high-impact Azure Advisor cost recommendations found"
                      } else {
                          "$($highImpactRecs.Count) unactioned high-impact Azure Advisor cost recommendation(s) found on subscription $SubscriptionId"
                      }
        Remediation = 'https://learn.microsoft.com/azure/advisor/advisor-cost-recommendations'
    })
} catch {
    Write-Warning "Invoke-CostManagementApi: Advisor recommendations check failed — $_"
}

return [PSCustomObject]@{
    Source   = 'cost-management'
    Findings = $findings.ToArray()
}
