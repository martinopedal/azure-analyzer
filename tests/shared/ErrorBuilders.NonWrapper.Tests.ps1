#Requires -Version 7.4
# Tests for issue #743 -- raw throws in shared/orchestrator code now route
# through New-FindingError / New-InstallerError. Each test asserts that the
# rendered error message carries the canonical [Source] Category: Reason
# prefix from Format-FindingErrorMessage so downstream log scrapers can
# classify the failure mode.

Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Sanitize.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Errors.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Canonicalize.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Compare-EntitySnapshots.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'ExecDashboardRender.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Installer.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Invoke-PRReviewGate.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Resolve-PRReviewThreads.ps1')
}

Describe 'shared:Compare-EntitySnapshots routes file-not-found through New-FindingError (#743)' {
    It 'throws a structured NotFound error when the snapshot path is missing' {
        $missing = Join-Path ([System.IO.Path]::GetTempPath()) ("missing-" + [guid]::NewGuid().ToString('N') + '.json')
        { Get-EntitySnapshotPayload -Path $missing } |
            Should -Throw -ExpectedMessage '*`[shared:Compare-EntitySnapshots] NotFound:*Snapshot not found*'
    }
}

Describe 'shared:ExecDashboardRender routes file-not-found through New-FindingError (#743)' {
    It 'throws a structured NotFound error when the results.json path is missing' {
        $missing = Join-Path ([System.IO.Path]::GetTempPath()) ("missing-" + [guid]::NewGuid().ToString('N') + '.json')
        { Get-ExecDashboardModel -InputPath $missing } |
            Should -Throw -ExpectedMessage '*`[shared:ExecDashboardRender] NotFound:*Results file not found*'
    }
}

Describe 'shared:Installer routes Get-FileHash256 file-not-found through New-InstallerError (#743)' {
    It 'throws an [installer]-prefixed error carrying the NotFound category' {
        $missing = Join-Path ([System.IO.Path]::GetTempPath()) ("missing-" + [guid]::NewGuid().ToString('N') + '.bin')
        { Get-FileHash256 -Path $missing } |
            Should -Throw -ExpectedMessage '*`[installer] Get-FileHash256 (none/NotFound):*File not found for hash computation*'
    }
}

Describe 'shared:Invoke-PRReviewGate routes Resolve-RepoParts validation through New-FindingError (#743)' {
    It 'throws a structured InvalidParameter error for malformed Repo' {
        { Resolve-RepoParts -Repo 'just-a-name' } |
            Should -Throw -ExpectedMessage '*`[shared:Invoke-PRReviewGate] InvalidParameter:*Repo must be in owner/name format*'
    }

    It 'throws a structured NotFound error when ModelResponsesPath is missing' {
        $missing = Join-Path ([System.IO.Path]::GetTempPath()) ("missing-" + [guid]::NewGuid().ToString('N') + '.json')
        { Get-ModelResponses -ModelResponsesPath $missing } |
            Should -Throw -ExpectedMessage '*`[shared:Invoke-PRReviewGate] NotFound:*ModelResponsesPath not found*'
    }
}

Describe 'shared:Resolve-PRReviewThreads routes Resolve-RepoOwnerName validation through New-FindingError (#743)' {
    It 'throws a structured InvalidParameter error for malformed Repo' {
        { Resolve-RepoOwnerName -Repo 'no-slash-here' } |
            Should -Throw -ExpectedMessage '*`[shared:Resolve-PRReviewThreads] InvalidParameter:*Repo must be in owner/name format*'
    }
}
