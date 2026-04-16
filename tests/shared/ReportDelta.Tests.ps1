#Requires -Version 7.4

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\ReportDelta.ps1')
}

Describe 'Get-FindingCompositeKey' {
    It 'builds the composite key from Source+ResourceId+Category+Title' {
        $finding = [PSCustomObject]@{
            Source = 'AzQR'
            ResourceId = '/Subscriptions/AAA/resourceGroups/RG/providers/Microsoft.Storage/storageAccounts/sa1'
            Category = 'Security'
            Title = 'Storage encryption disabled'
        }

        $key = Get-FindingCompositeKey -Finding $finding
        $key | Should -Be 'azqr|/subscriptions/aaa/resourcegroups/rg/providers/microsoft.storage/storageaccounts/sa1|security|storage encryption disabled'
    }
}

Describe 'Get-FindingDelta' {
    It 'marks current findings as New or Unchanged and counts Resolved findings' {
        $previous = @(
            [PSCustomObject]@{ Id='old-1'; Source='azqr'; ResourceId='r1'; Category='Security'; Title='A'; Severity='High'; Compliant=$false },
            [PSCustomObject]@{ Id='old-2'; Source='azqr'; ResourceId='r2'; Category='Security'; Title='B'; Severity='Medium'; Compliant=$false }
        )

        $current = @(
            [PSCustomObject]@{ Id='new-1'; Source='azqr'; ResourceId='r1'; Category='Security'; Title='A'; Severity='High'; Compliant=$false },
            [PSCustomObject]@{ Id='new-2'; Source='psrule'; ResourceId='r3'; Category='Compute'; Title='C'; Severity='Low'; Compliant=$true }
        )

        $delta = Get-FindingDelta -CurrentFindings $current -PreviousFindings $previous

        $delta.NewCount | Should -Be 1
        $delta.UnchangedCount | Should -Be 1
        $delta.ResolvedCount | Should -Be 1
        $delta.ResolvedFindings.Count | Should -Be 1
        $delta.ResolvedFindings[0].DeltaStatus | Should -Be 'Resolved'
        $delta.ResolvedFindings[0].Title | Should -Be 'B'

        (@($delta.CurrentFindings | Where-Object { $_.Id -eq 'new-1' })[0].DeltaStatus) | Should -Be 'Unchanged'
        (@($delta.CurrentFindings | Where-Object { $_.Id -eq 'new-2' })[0].DeltaStatus) | Should -Be 'New'
    }

    It 'calculates net non-compliant change between runs' {
        $previous = @(
            [PSCustomObject]@{ Id='old-1'; Source='azqr'; ResourceId='r1'; Category='Security'; Title='A'; Compliant=$false },
            [PSCustomObject]@{ Id='old-2'; Source='azqr'; ResourceId='r2'; Category='Security'; Title='B'; Compliant=$false }
        )
        $current = @(
            [PSCustomObject]@{ Id='new-1'; Source='azqr'; ResourceId='r1'; Category='Security'; Title='A'; Compliant=$false }
        )

        $delta = Get-FindingDelta -CurrentFindings $current -PreviousFindings $previous

        $delta.PreviousNonCompliantCount | Should -Be 2
        $delta.CurrentNonCompliantCount | Should -Be 1
        $delta.NetNonCompliantChange | Should -Be -1
    }
}
