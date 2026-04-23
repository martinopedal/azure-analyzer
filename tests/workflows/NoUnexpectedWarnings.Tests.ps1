#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Contract test (#770): every wrapper test file must either capture host
    output (Warning / Information streams) and assert on it, or be explicitly
    tagged with -Tag 'AllowsWarning'.

.DESCRIPTION
    Issue #770 documented WARNING: lines slipping through wrapper smoke tests
    because the assertions only inspected the return object. To prevent this
    class of regression, every test file under tests/wrappers/ must:

      1. Reference Invoke-WrapperWithHostCapture (the canonical capture seam)
         and assert that captured warnings are empty / explicitly expected;
      OR
      2. Source Suppress-WrapperWarnings.ps1 (the legacy class B suppressor,
         which down-grades known soft-fail warnings to Verbose);
      OR
      3. Carry a top-level `-Tag 'AllowsWarning'` annotation on its Describe.

    Files that match none of these are flagged here so the next person to
    write a wrapper test cannot quietly drop the assertion.
#>

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:WrapperTestDir = Join-Path $script:RepoRoot 'tests' 'wrappers'

    # ---------------------------------------------------------------------
    # Grandfathered baseline (#770).
    # These wrapper tests pre-date the host-output-capture contract. Adding
    # the assertion to all of them at once is out of scope for this PR;
    # instead we ratchet: any net-new wrapper test MUST satisfy the contract
    # (capture host output, source the suppressor, or be tagged AllowsWarning).
    # When a grandfathered file is updated to comply, REMOVE it from this list
    # so it cannot regress. Adding a new file here requires reviewer approval.
    # ---------------------------------------------------------------------
    $script:GrandfatheredBaseline = @(
        'Invoke-AdoConsumption.Tests.ps1',
        'Invoke-ADOPipelineCorrelator.Tests.ps1',
        'Invoke-ADOPipelineSecurity.Tests.ps1',
        'Invoke-ADORepoSecrets.Tests.ps1',
        'Invoke-ADOServiceConnections.Tests.ps1',
        'Invoke-AksKarpenterCost.Tests.ps1',
        'Invoke-AksRightsizing.Tests.ps1',
        'Invoke-AppInsights.Tests.ps1',
        'Invoke-AzGovViz.Tests.ps1',
        'Invoke-Azqr.Tests.ps1',
        'Invoke-AzureCost.Tests.ps1',
        'Invoke-AzureLoadTesting.Tests.ps1',
        'Invoke-AzureQuotaReports.Tests.ps1',
        'Invoke-DefenderForCloud.Tests.ps1',
        'Invoke-Falco.Tests.ps1',
        'Invoke-FinOpsSignals.Tests.ps1',
        'Invoke-GhActionsBilling.Tests.ps1',
        'Invoke-Gitleaks.Tests.ps1',
        'Invoke-IaCBicep.E2E.Tests.ps1',
        'Invoke-IaCBicep.Tests.ps1',
        'Invoke-IaCTerraform.E2E.Tests.ps1',
        'Invoke-IaCTerraform.Tests.ps1',
        'Invoke-IdentityCorrelation.Tests.ps1',
        'Invoke-IdentityGraphExpansion.Tests.ps1',
        'Invoke-Infracost.E2E.Tests.ps1',
        'Invoke-Infracost.Sanitize.Tests.ps1',
        'Invoke-Infracost.Tests.ps1',
        'Invoke-KubeBench.LastExitCode.Tests.ps1',
        'Invoke-KubeBench.Tests.ps1',
        'Invoke-Kubescape.Tests.ps1',
        'Invoke-Maester.Tests.ps1',
        'Invoke-Powerpipe.Tests.ps1',
        'Invoke-Prowler.Tests.ps1',
        'Invoke-PSRule.Tests.ps1',
        'Invoke-SentinelCoverage.Tests.ps1',
        'Invoke-SentinelIncidents.Tests.ps1',
        'Invoke-Trivy.Tests.ps1',
        'Invoke-WARA.Tests.ps1',
        'Invoke-Zizmor.Tests.ps1',
        'MissingToolRuntime.Tests.ps1',
        'Wrappers-Remote.Tests.ps1',
        'Wrappers-Sanitize.Tests.ps1'
    )
}

Describe 'Wrapper test contract: host output must be captured or explicitly allowed (#770)' {
    It '<File> captures host output, suppresses warnings, or is tagged AllowsWarning' -ForEach @(
        Get-ChildItem -Path (Join-Path (Split-Path $PSCommandPath -Parent) '..' 'wrappers') -Filter '*.Tests.ps1' -File |
            ForEach-Object { @{ File = $_.Name; Path = $_.FullName } }
    ) {
        $content = Get-Content $Path -Raw -ErrorAction Stop

        $hasCapture       = $content -match 'Invoke-WrapperWithHostCapture'
        $hasSuppression   = $content -match 'Suppress-WrapperWarnings\.ps1|Enable-WrapperWarningSuppression'
        $hasAllowsWarning = $content -match "-Tag\s+['""]AllowsWarning['""]"

        $compliant = $hasCapture -or $hasSuppression -or $hasAllowsWarning

        if (-not $compliant -and ($script:GrandfatheredBaseline -contains $File)) {
            Set-ItResult -Skipped -Because "$File is grandfathered (#770 baseline). Remove from baseline once it adopts Invoke-WrapperWithHostCapture / Suppress-WrapperWarnings / -Tag AllowsWarning."
            return
        }

        if ($compliant -and ($script:GrandfatheredBaseline -contains $File)) {
            throw "$File now satisfies the #770 contract. Remove it from `$script:GrandfatheredBaseline in tests/workflows/NoUnexpectedWarnings.Tests.ps1 to lock the win in."
        }

        $compliant | Should -BeTrue -Because @"
$File runs wrapper code but neither captures host output via
Invoke-WrapperWithHostCapture, sources Suppress-WrapperWarnings.ps1, nor
declares -Tag 'AllowsWarning'. This is the contract violation that #770
was opened to prevent. Add one of the three before merging.
"@
    }
}
