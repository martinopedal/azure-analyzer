@{
    RootModule            = 'AzureAnalyzer.psm1'
    ModuleVersion         = '1.1.1' # x-release-please-version
    GUID                  = '6d44ac09-67b5-4f66-9539-43707cd767fc'
    Author                = 'Martin Opedal'
    CompanyName           = 'Azure Community'
    Description           = 'Unified Azure assessment tool bundling azqr, PSRule for Azure, AzGovViz, ALZ Resource Graph queries, WARA, Maester, and OpenSSF Scorecard. Local module for on-demand assessment runs.'
    
    PowerShellVersion     = '7.4'
    
    RequiredModules       = @()
    
    FunctionsToExport     = @(
        'Invoke-AzureAnalyzer',
        'New-HtmlReport',
        'New-MdReport'
    )
    
    CmdletsToExport       = @()
    VariablesToExport     = @()
    AliasesToExport       = @()

    PrivateData           = @{
        PSData = @{
            Tags         = @('Azure', 'Assessment', 'Compliance', 'Security', 'Governance', 'PSRule', 'azqr', 'AzGovViz', 'AzureLandingZones', 'WellArchitected')
            LicenseUri   = 'https://github.com/martinopedal/azure-analyzer/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/martinopedal/azure-analyzer'
            ReleaseNotes = 'https://github.com/martinopedal/azure-analyzer/blob/main/CHANGELOG.md'
            # IconUri    = ''  # Optional - leave commented; don't add an empty string (worse than absent)
        }
    }
}
