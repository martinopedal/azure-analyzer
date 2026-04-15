@{
    RootModule            = 'AzureAnalyzer.psm1'
    ModuleVersion         = '2.0.0'
    GUID                  = '0e0f0e0f-0f0e-0f0e-0f0e-0f0e0f0e0f0e'
    Author                = 'Martin Opedal'
    CompanyName           = 'Azure Community'
    Description           = 'Unified Azure assessment tool bundling azqr, PSRule for Azure, AzGovViz, ALZ Resource Graph queries, WARA, Maester, and OpenSSF Scorecard into a single orchestrated run with unified JSON, HTML, and Markdown reports.'
    
    PowerShellVersion     = '7.0'
    
    RequiredModules       = @(
        @{ ModuleName = 'Az.Accounts'; ModuleVersion = '2.13.0'; },
        @{ ModuleName = 'Az.ResourceGraph'; ModuleVersion = '0.13.0'; }
    )
    
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
            Tags                     = @('Azure', 'Assessment', 'Compliance', 'Security', 'Governance', 'PSRule', 'WARA', 'AzGovViz')
            LicenseUri               = 'https://github.com/martinopedal/azure-analyzer/blob/main/LICENSE'
            ProjectUri               = 'https://github.com/martinopedal/azure-analyzer'
            IconUri                  = ''
            ReleaseNotes             = @'
# v2.0.0 Release Notes

## Major Features
- Unified module packaging for PSGallery distribution
- All seven assessment tools now available via single Install-Module command
- Integrated report generation (HTML, Markdown, JSON)
- AI-assisted triage for prioritized findings

## Tools Included
1. **azqr** - Azure Quick Review
2. **PSRule for Azure** - Policy validation
3. **AzGovViz** - Governance hierarchy
4. **ALZ Queries** - Azure Resource Graph queries
5. **WARA** - Well-Architected Review
6. **Maester** - Entra ID security
7. **OpenSSF Scorecard** - Repository security

## Breaking Changes
- Module now uses unified schema for all findings
- New parameter contract for Invoke-AzureAnalyzer

See https://github.com/martinopedal/azure-analyzer/blob/main/CHANGELOG.md for full details.
'@
            Prerelease               = ''
        }
    }
    
    FileList              = @(
        'AzureAnalyzer.psd1',
        'AzureAnalyzer.psm1',
        'Invoke-AzureAnalyzer.ps1',
        'New-HtmlReport.ps1',
        'New-MdReport.ps1',
        'modules/Invoke-Azqr.ps1',
        'modules/Invoke-PSRule.ps1',
        'modules/Invoke-AzGovViz.ps1',
        'modules/Invoke-AlzQueries.ps1',
        'modules/Invoke-WARA.ps1',
        'modules/Invoke-Maester.ps1',
        'modules/Invoke-CopilotTriage.ps1',
        'modules/Invoke-CopilotTriage.py',
        'queries/',
        'samples/',
        'docs/'
    )
}
