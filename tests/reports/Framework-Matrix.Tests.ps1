#Requires -Version 7.4

Describe 'HTML report framework coverage matrix' {
    BeforeAll {
        $script:RootDir = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
        $script:ManifestPath = Join-Path $RootDir 'tools' 'tool-manifest.json'
    }

    It 'renders Framework Coverage rows from manifest mappings' {
        $tmp = Join-Path $TestDrive 'framework-matrix-rows'
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $resultsPath = Join-Path $tmp 'results.json'
        '[]' | Set-Content -Path $resultsPath -Encoding UTF8
        $outputPath = Join-Path $tmp 'report.html'

        & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath $resultsPath -OutputPath $outputPath | Out-Null
        $html = Get-Content $outputPath -Raw

        $html | Should -Match 'id="framework-coverage-matrix"'
        $html | Should -Match 'Framework Coverage'

        $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
        $required = @('CIS Azure', 'NIST 800-53', 'Azure WAF', 'Azure CAF', 'SOC2', 'PCI-DSS')
        $mapped = @(
            $manifest.tools |
            Where-Object { $_.enabled -and $_.frameworks } |
            ForEach-Object { @($_.frameworks) }
        )
        $frameworks = @($required + $mapped | Sort-Object -Unique)
        foreach ($fw in $frameworks) {
            $html | Should -Match ("<tr data-framework='{0}'>" -f [Regex]::Escape($fw))
        }
    }

    It 'renders matrix cell counts for tool/framework intersections' {
        $tmp = Join-Path $TestDrive 'framework-matrix-counts'
        $null = New-Item -ItemType Directory -Path $tmp -Force

        $findings = @(
            [pscustomobject]@{ Id='F-1'; Source='azqr';  Category='Security'; Title='WAF policy check'; Severity='High'; Compliant=$false; Detail='d'; Remediation='r'; ResourceId='/subscriptions/a/resourceGroups/rg/providers/Microsoft.Network/firewallPolicies/p1'; LearnMoreUrl=''; Platform='Azure'; Controls=@(); Frameworks=@('Azure WAF') }
            [pscustomobject]@{ Id='F-2'; Source='azqr';  Category='Security'; Title='WAF policy check 2'; Severity='Low'; Compliant=$false; Detail='d'; Remediation='r'; ResourceId='/subscriptions/a/resourceGroups/rg/providers/Microsoft.Network/firewallPolicies/p2'; LearnMoreUrl=''; Platform='Azure'; Controls=@(); Frameworks=@('Azure WAF','Azure CAF') }
            [pscustomobject]@{ Id='F-3'; Source='trivy'; Category='Security'; Title='CVE-1'; Severity='Critical'; Compliant=$false; Detail='d'; Remediation='r'; ResourceId='repo://x'; LearnMoreUrl=''; Platform='GitHub'; Controls=@(); Frameworks=@('NIST 800-53') }
            [pscustomobject]@{ Id='F-4'; Source='trivy'; Category='Security'; Title='CVE-2'; Severity='Medium'; Compliant=$false; Detail='d'; Remediation='r'; ResourceId='repo://y'; LearnMoreUrl=''; Platform='GitHub'; Controls=@(); Frameworks=@('NIST 800-53') }
            [pscustomobject]@{ Id='F-5'; Source='trivy'; Category='Security'; Title='CVE-3'; Severity='Info'; Compliant=$true; Detail='d'; Remediation='r'; ResourceId='repo://z'; LearnMoreUrl=''; Platform='GitHub'; Controls=@(); Frameworks=@('PCI-DSS') }
        )

        $resultsPath = Join-Path $tmp 'results.json'
        $findings | ConvertTo-Json -Depth 8 | Set-Content -Path $resultsPath -Encoding UTF8
        $outputPath = Join-Path $tmp 'report.html'

        & (Join-Path $RootDir 'New-HtmlReport.ps1') -InputPath $resultsPath -OutputPath $outputPath | Out-Null
        $html = Get-Content $outputPath -Raw

        $html | Should -Match 'data-source=''azqr'' data-framework=''Azure WAF'''
        $html | Should -Match 'data-source=''azqr'' data-framework=''Azure CAF'''
        $html | Should -Match 'data-source=''trivy'' data-framework=''NIST 800-53'''

        $html | Should -Match "<button type='button' class='fxm-button fxm-button-hit' data-source='azqr' data-framework='Azure WAF'[^>]*>\s*<span class='fxm-cell-count'>2</span>"
        $html | Should -Match "<button type='button' class='fxm-button fxm-button-hit' data-source='azqr' data-framework='Azure CAF'[^>]*>\s*<span class='fxm-cell-count'>1</span>"
        $html | Should -Match "<button type='button' class='fxm-button fxm-button-hit' data-source='trivy' data-framework='NIST 800-53'[^>]*>\s*<span class='fxm-cell-count'>2</span>"
    }
}
