@{
    RootModule            = 'AzureAnalyzer.psm1'
    ModuleVersion         = '1.0.0'
    GUID                  = '0e0f0e0f-0f0e-0f0e-0f0e-0f0e0f0e0f0e'
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
}
