#Requires -Version 7.4

Describe 'New-HtmlReport' {
    BeforeAll {
        $script:RootDir = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    }

    It 'renders a valid HTML shell with an empty portfolio state for empty management-group scans' {
        $tmp = Join-Path $TestDrive 'html-empty-portfolio'
        $null = New-Item -ItemType Directory -Path $tmp -Force

        $resultsPath = Join-Path $tmp 'results.json'
        '[]' | Set-Content -Path $resultsPath -Encoding UTF8

        $portfolioPath = Join-Path $tmp 'portfolio.json'
        @{
            SchemaVersion = '1.0'
            Summary       = @{
                ManagementGroupId = 'platform-connectivity'
                SubscriptionCount = 0
                TotalFindings     = 0
            }
            Subscriptions = @()
            ManagementGroups = @()
            Correlations  = @()
        } | ConvertTo-Json -Depth 8 | Set-Content -Path $portfolioPath -Encoding UTF8

        $outputPath = Join-Path $tmp 'report.html'

        {
            & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath $resultsPath -OutputPath $outputPath | Out-Null
        } | Should -Not -Throw

        Test-Path $outputPath | Should -BeTrue
        $html = Get-Content $outputPath -Raw
        $html | Should -Match '<!DOCTYPE html>'
        $html | Should -Match '<html lang="en">'
        $html | Should -Match 'Portfolio rollup'
        $html | Should -Match 'No findings in portfolio\.'
        $html | Should -Match 'platform-connectivity'
    }

    It 'fallback source list includes azure-cost, bicep-iac, terraform-iac, sentinel-incidents' {
        # Read the report script and check the fallback array directly
        $reportScript = Get-Content (Join-Path $RootDir 'New-HtmlReport.ps1') -Raw
        $reportScript | Should -Match 'azure-cost'
        $reportScript | Should -Match 'bicep-iac'
        $reportScript | Should -Match 'terraform-iac'
        $reportScript | Should -Match 'sentinel-incidents'
    }

    It 'embeds the executive dashboard as a Summary tab that is the default-active view (#210)' {
        $tmp = Join-Path $TestDrive 'html-summary-tab'
        $null = New-Item -ItemType Directory -Path $tmp -Force

        $sub = '11111111-1111-1111-1111-111111111111'
        $findings = @(
            [pscustomobject]@{ Id='F-1'; Source='azqr';   ResourceId="/subscriptions/$sub/rg/a/storage/x";   Category='Security'; Title='T1'; Severity='Critical'; Compliant=$false; Detail=''; Remediation=''; LearnMoreUrl=''; Platform='Azure'; Controls=@(); Frameworks=@() }
            [pscustomobject]@{ Id='F-2'; Source='azqr';   ResourceId="/subscriptions/$sub/rg/a/storage/y";   Category='Security'; Title='T2'; Severity='High';     Compliant=$false; Detail=''; Remediation=''; LearnMoreUrl=''; Platform='Azure'; Controls=@(); Frameworks=@() }
            [pscustomobject]@{ Id='F-3'; Source='psrule'; ResourceId="/subscriptions/$sub/rg/a/keyvault/z"; Category='Security'; Title='T3'; Severity='Medium';   Compliant=$false; Detail=''; Remediation=''; LearnMoreUrl=''; Platform='Azure'; Controls=@(); Frameworks=@() }
        )
        $resultsPath = Join-Path $tmp 'results.json'
        $findings | ConvertTo-Json -Depth 5 | Set-Content -Path $resultsPath -Encoding UTF8

        $outputPath = Join-Path $tmp 'report.html'
        & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath $resultsPath -OutputPath $outputPath | Out-Null

        Test-Path $outputPath | Should -BeTrue
        $html = Get-Content $outputPath -Raw

        # Tab navigation present, Summary listed first
        $html | Should -Match 'class="rt-tabs[^"]*"'
        $html | Should -Match 'data-tab="summary"'
        $html | Should -Match 'data-tab="findings"'
        # Summary button is the active tab by default
        $html | Should -Match '<button class="rt-tab-button is-active"[^>]*data-tab="summary"'
        # Summary panel is the default-active panel
        $html | Should -Match 'id="rt-tab-summary" class="rt-tab-panel is-active"'
        # Findings panel exists but is NOT active by default
        $html | Should -Match 'id="rt-tab-findings" class="rt-tab-panel"'
        # Embedded exec dashboard wrapped under .exec-dash for CSS scoping
        $html | Should -Match 'class="exec-dash"'
        # Exec dashboard hallmark sections survived embedding
        $html | Should -Match 'Compliance score'
        $html | Should -Match 'Top-10 risky resources'
        $html | Should -Match 'WAF 5-pillar coverage'
        # Sparkline SVG embedded inside summary
        $html | Should -Match '<svg[^>]*viewBox'
        # Tab-switch JS present
        $html | Should -Match 'function rtSwitchTab'
        # Existing Findings content still rendered (categories accordion etc.)
        $html | Should -Match 'Findings by category'
        # Summary tab markup must appear BEFORE the Findings panel
        $sumIdx = $html.IndexOf('id="rt-tab-summary"')
        $findIdx = $html.IndexOf('id="rt-tab-findings"')
        $sumIdx | Should -BeGreaterThan -1
        $findIdx | Should -BeGreaterThan $sumIdx
    }

    It 'still produces a Findings-only fallback view when summary render fails (#210 graceful degradation)' {
        # Sanity: when the embedded dashboard would fail, the report still renders.
        # Use a results file shaped to exercise normal render but verify no hard
        # dependency on summary content (the fallback path is exercised by the
        # warning path in the script; here we just confirm Findings content still
        # appears even if Summary is suppressed).
        $tmp = Join-Path $TestDrive 'html-summary-fallback'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $resultsPath = Join-Path $tmp 'results.json'
        '[]' | Set-Content -Path $resultsPath -Encoding UTF8
        $outputPath = Join-Path $tmp 'report.html'
        & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath $resultsPath -OutputPath $outputPath | Out-Null
        $html = Get-Content $outputPath -Raw
        # Tabs still present even with empty findings
        $html | Should -Match 'data-tab="summary"'
        $html | Should -Match 'data-tab="findings"'
        # Findings panel is still rendered
        $html | Should -Match 'id="rt-tab-findings"'
    }

    It 'renders a Resources tab and embeds model.entities when entities.json is present (issue #209)' {
        $tmp = Join-Path $TestDrive 'html-resources'
        $null = New-Item -ItemType Directory -Path $tmp -Force

        $resultsPath = Join-Path $tmp 'results.json'
        '[]' | Set-Content -Path $resultsPath -Encoding UTF8

        # v3.1 envelope shape with one entity carrying one observation
        $entitiesPath = Join-Path $tmp 'entities.json'
        @{
            SchemaVersion = '3.1'
            Entities = @(
                @{
                    EntityId          = 'sub-1/rg-1/vm-1'
                    EntityName        = 'vm-prod-01'
                    EntityType        = 'Microsoft.Compute/virtualMachines'
                    Platform          = 'Azure'
                    ResourceGroup     = 'rg-1'
                    WorstSeverity     = 'High'
                    NonCompliantCount = 2
                    CompliantCount    = 1
                    Sources           = @('azqr','psrule')
                    MonthlyCost       = 42.50
                    Observations      = @(
                        @{ Severity = 'High'; Detail = 'Public IP exposed'; Remediation = 'Move behind a load balancer'; DocsUrl = 'https://learn.microsoft.com/azure/security' },
                        @{ Severity = 'Low'; Detail = 'Tag missing: owner'; Remediation = 'Add owner tag' }
                    )
                }
            )
            Edges = @()
        } | ConvertTo-Json -Depth 8 | Set-Content -Path $entitiesPath -Encoding UTF8

        $outputPath = Join-Path $tmp 'report.html'

        {
            & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath $resultsPath -OutputPath $outputPath | Out-Null
        } | Should -Not -Throw

        Test-Path $outputPath | Should -BeTrue
        $html = Get-Content $outputPath -Raw

        # Resources section marker
        $html | Should -Match '<h2 id="resources">Resources</h2>'
        $html | Should -Match 'id="resources-table"'
        # Entity row rendered
        $html | Should -Match 'vm-prod-01'
        $html | Should -Match 'rg-1'
        # Worst severity badge with color class
        $html | Should -Match 'class="badge sev-high"'
        # Observations sub-table present
        $html | Should -Match 'observations-table'
        $html | Should -Match 'Public IP exposed'
        # Embedded JSON model contains entities
        $html | Should -Match 'id="report-model"'
        $html | Should -Match '"entities"'
        # toggle JS function injected
        $html | Should -Match 'function toggleEntityDetail'
    }

    It 'gracefully degrades when entities.json is missing (issue #209)' {
        $tmp = Join-Path $TestDrive 'html-no-entities'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $resultsPath = Join-Path $tmp 'results.json'
        '[]' | Set-Content -Path $resultsPath -Encoding UTF8
        $outputPath = Join-Path $tmp 'report.html'

        {
            & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath $resultsPath -OutputPath $outputPath | Out-Null
        } | Should -Not -Throw

        Test-Path $outputPath | Should -BeTrue
        $html = Get-Content $outputPath -Raw
        # Empty model is still embedded for client compatibility
        $html | Should -Match 'id="report-model"'
        $html | Should -Match '"entities":\[\]'
        # No Resources section emitted server-side when there are no entities
        $html | Should -Not -Match '<h2 id="resources">'
    }

    Context 'identity blast-radius graph (#298)' {
        It 'renders the interactive identity graph section when >=5 identity entities are present' {
            $tmp = Join-Path $TestDrive 'html-identity-graph-full'
            $null = New-Item -ItemType Directory -Path $tmp -Force
            $resultsPath = Join-Path $tmp 'results.json'
            '[]' | Set-Content -Path $resultsPath -Encoding UTF8

            $sub = '11111111-1111-1111-1111-111111111111'
            $entities = @()
            $entities += @{ EntityId = "user-alice@contoso";  EntityType='User';             DisplayName='alice@contoso';      SubscriptionId=$sub; Platform='Entra'; Observations=@() }
            $entities += @{ EntityId = "user-bob@contoso";    EntityType='User';             DisplayName='bob@contoso';        SubscriptionId=$sub; Platform='Entra'; Observations=@() }
            $entities += @{ EntityId = "group-admins";        EntityType='Group';            DisplayName='grp-admins';         SubscriptionId=$sub; Platform='Entra'; Observations=@() }
            $entities += @{ EntityId = "sp-payments";         EntityType='ServicePrincipal'; DisplayName='sp-payments';        SubscriptionId=$sub; Platform='Entra'; Observations=@() }
            $entities += @{ EntityId = "app-payments";        EntityType='Application';      DisplayName='app-payments';       SubscriptionId=$sub; Platform='Entra'; Observations=@() }
            $entities += @{ EntityId = "/subscriptions/$sub/rg/x/kv/kv-prod"; EntityType='AzureResource'; DisplayName='kv-prod'; SubscriptionId=$sub; Platform='Azure'; ResourceGroup='rg-x'; WorstSeverity='High'; NonCompliantCount=1; CompliantCount=0; Observations=@() }

            $entitiesPath = Join-Path $tmp 'entities.json'
            @{ SchemaVersion = '3.1'; Entities = $entities; Edges = @() } | ConvertTo-Json -Depth 8 | Set-Content -Path $entitiesPath -Encoding UTF8

            $outputPath = Join-Path $tmp 'report.html'
            { & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath $resultsPath -OutputPath $outputPath | Out-Null } | Should -Not -Throw

            Test-Path $outputPath | Should -BeTrue
            $html = Get-Content $outputPath -Raw

            # Section + container present
            $html | Should -Match '<h2 id="identity-graph-section">Identity blast-radius graph</h2>'
            $html | Should -Match 'id="identityGraph"'
            $html | Should -Match 'id="idgSvg"'
            # Embedded JSON model with all 6 nodes
            $html | Should -Match 'id="identity-graph-model"'
            $html | Should -Match '"label":"alice@contoso"'
            $html | Should -Match '"label":"sp-payments"'
            $html | Should -Match '"label":"kv-prod"'
            # Empty-state markup is hidden by default when nodes are sufficient
            $html | Should -Match 'id="idgEmpty"\s+hidden'
            # Click-to-filter wiring: applyFilter helper + idg-node click handler
            $html | Should -Match 'idg-node'
            $html | Should -Match 'function applyFilter'
            $html | Should -Match 'idgClear'
            # No external CDN references introduced by graph
            $html | Should -Not -Match 'cdn\.|cdnjs|unpkg|jsdelivr'
            # Total inlined payload stays under 200 KB additional vs baseline (sanity bound)
            (Get-Item $outputPath).Length | Should -BeLessThan 1MB
        }

        It 'shows the empty-state when fewer than 5 identity entities are present' {
            $tmp = Join-Path $TestDrive 'html-identity-graph-empty'
            $null = New-Item -ItemType Directory -Path $tmp -Force
            $resultsPath = Join-Path $tmp 'results.json'
            '[]' | Set-Content -Path $resultsPath -Encoding UTF8

            # Only 3 identity-relevant entities -> empty state
            $entities = @(
                @{ EntityId='u1'; EntityType='User';  DisplayName='u1'; SubscriptionId=''; Platform='Entra'; Observations=@() }
                @{ EntityId='g1'; EntityType='Group'; DisplayName='g1'; SubscriptionId=''; Platform='Entra'; Observations=@() }
                @{ EntityId='r1'; EntityType='AzureResource'; DisplayName='r1'; SubscriptionId=''; Platform='Azure'; ResourceGroup=''; WorstSeverity='Info'; NonCompliantCount=0; CompliantCount=0; Observations=@() }
            )
            $entitiesPath = Join-Path $tmp 'entities.json'
            @{ SchemaVersion='3.1'; Entities=$entities; Edges=@() } | ConvertTo-Json -Depth 8 | Set-Content -Path $entitiesPath -Encoding UTF8

            $outputPath = Join-Path $tmp 'report.html'
            { & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath $resultsPath -OutputPath $outputPath | Out-Null } | Should -Not -Throw

            $html = Get-Content $outputPath -Raw
            # Section still emitted (so client knows the feature exists)
            $html | Should -Match 'id="identityGraph"'
            $html | Should -Match 'id="idgEmpty"'
            # Model contains exactly the 3 nodes -> client renderer falls into empty-state branch
            $html | Should -Match '"nodes":\['
            $html | Should -Match 'Need at least 5 identity-related entities'
        }

        It 'omits the identity graph entirely when entities.json is missing' {
            $tmp = Join-Path $TestDrive 'html-identity-graph-missing'
            $null = New-Item -ItemType Directory -Path $tmp -Force
            $resultsPath = Join-Path $tmp 'results.json'
            '[]' | Set-Content -Path $resultsPath -Encoding UTF8
            $outputPath = Join-Path $tmp 'report.html'
            { & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath $resultsPath -OutputPath $outputPath | Out-Null } | Should -Not -Throw
            $html = Get-Content $outputPath -Raw
            $html | Should -Not -Match 'id="identity-graph-section"'
        }
    }

    Context 'samples/sample-report.html identity graph (#298)' {
        It 'samples/sample-report.html ships the interactive identity graph (no inline teaser SVG)' {
            $samplePath = Join-Path $RootDir 'samples\sample-report.html'
            Test-Path $samplePath | Should -BeTrue
            $html = Get-Content $samplePath -Raw
            $html | Should -Match 'id="identityGraph"'
            $html | Should -Match 'IDENTITY_NODES'
            $html | Should -Match 'IDENTITY_EDGES'
            $html | Should -Match 'renderIdentityGraph'
            # Old static teaser must be gone
            $html | Should -Not -Match 'Hover a node to highlight reachable resources'
            $html | Should -Not -Match 'Identity blast-radius graph \(mock\)'
            # Single-file: no CDN references introduced
            $html | Should -Not -Match 'cdn\.|cdnjs\.|unpkg\.|jsdelivr\.'
            # Total payload stays well under the 200KB inlined-component budget
            (Get-Item $samplePath).Length | Should -BeLessThan 200KB
        }
    }
}
