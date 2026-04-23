#Requires -Version 7.4

Describe 'ADO parameter compatibility aliases' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
        $orchestratorCmd = Get-Command -Name (Join-Path $repoRoot 'Invoke-AzureAnalyzer.ps1')
        $adoWrapperCmd = Get-Command -Name (Join-Path $repoRoot 'modules\Invoke-ADOServiceConnections.ps1')
        $adoPipelineWrapperCmd = Get-Command -Name (Join-Path $repoRoot 'modules\Invoke-ADOPipelineSecurity.ps1')
        $adoSecretsWrapperCmd = Get-Command -Name (Join-Path $repoRoot 'modules\Invoke-ADORepoSecrets.ps1')
        $adoCorrelatorWrapperCmd = Get-Command -Name (Join-Path $repoRoot 'modules\Invoke-ADOPipelineCorrelator.ps1')
        $adoConsumptionWrapperCmd = Get-Command -Name (Join-Path $repoRoot 'modules\Invoke-AdoConsumption.ps1')
    }

    It 'supports -AdoOrganization alias on orchestrator and wrapper' {
        $orchestratorCmd.Parameters['AdoOrg'].Aliases | Should -Contain 'AdoOrganization'
        $adoWrapperCmd.Parameters['AdoOrg'].Aliases | Should -Contain 'AdoOrganization'
        $adoPipelineWrapperCmd.Parameters['AdoOrg'].Aliases | Should -Contain 'AdoOrganization'
        $adoSecretsWrapperCmd.Parameters['AdoOrg'].Aliases | Should -Contain 'AdoOrganization'
        $adoCorrelatorWrapperCmd.Parameters['AdoOrg'].Aliases | Should -Contain 'AdoOrganization'
    }

    It 'supports -AdoPatToken alias on orchestrator and wrapper' {
        $orchestratorCmd.Parameters['AdoPat'].Aliases | Should -Contain 'AdoPatToken'
        $adoWrapperCmd.Parameters['AdoPat'].Aliases | Should -Contain 'AdoPatToken'
        $adoPipelineWrapperCmd.Parameters['AdoPat'].Aliases | Should -Contain 'AdoPatToken'
        $adoSecretsWrapperCmd.Parameters['AdoPat'].Aliases | Should -Contain 'AdoPatToken'
        $adoCorrelatorWrapperCmd.Parameters['AdoPat'].Aliases | Should -Contain 'AdoPatToken'
    }

    It 'keeps Organization/Project aliases on ado-consumption for backward compatibility' {
        $adoConsumptionWrapperCmd.Parameters['AdoOrg'].Aliases | Should -Contain 'Organization'
        $adoConsumptionWrapperCmd.Parameters['AdoProject'].Aliases | Should -Contain 'Project'
    }
}
