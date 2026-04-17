#Requires -Version 7.2

param(
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\modules\shared\Sanitize.ps1')

function Invoke-GhCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [switch] $AllowFailure
    )

    try {
        $output = & gh @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0 -and -not $AllowFailure) {
            throw "gh $($Arguments -join ' ') failed with exit code ${exitCode}: $output"
        }

        return [pscustomobject]@{
            Output   = [string]($output -join [Environment]::NewLine)
            ExitCode = $exitCode
        }
    } catch {
        if ($AllowFailure) {
            return [pscustomobject]@{
                Output   = [string]$_.Exception.Message
                ExitCode = 1
            }
        }

        throw $_
    }
}

function Get-CiErrorHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $WorkflowName,

        [Parameter(Mandatory)]
        [string] $FirstErrorLine
    )

    $inputText = "$WorkflowName|$FirstErrorLine"
    $hashBytes = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($inputText))
    $hashHex = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    return $hashHex.Substring(0, 12)
}

function Get-FirstErrorLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RawLog
    )

    $line = $RawLog -split "`r?`n" | Select-Object -First 500 | Where-Object { $_ -match '(?i)(error|failed|fatal):' } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($line)) {
        return 'No explicit error line found in failed log output.'
    }

    return (Remove-Credentials $line).Trim()
}

function Get-FailedJobNames {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [long] $RunId
    )

    $jobsResponse = Invoke-GhCommand -Arguments @('run', 'view', $RunId, '--json', 'jobs')
    $jobsObject = $jobsResponse.Output | ConvertFrom-Json
    $failedJobs = @($jobsObject.jobs | Where-Object { $_.conclusion -eq 'failure' } | ForEach-Object { $_.name })
    if ($failedJobs.Count -eq 0) {
        return 'unknown'
    }

    return (Remove-Credentials ($failedJobs -join ', '))
}

function Get-PrUrlForRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Repo,

        [Parameter(Mandatory)]
        [long] $RunId
    )

    $runDetails = Invoke-GhCommand -Arguments @('api', "/repos/$Repo/actions/runs/$RunId")
    $runObject = $runDetails.Output | ConvertFrom-Json
    $firstPr = @($runObject.pull_requests | Select-Object -First 1)
    if ($firstPr.Count -eq 0) {
        return ''
    }

    return (Remove-Credentials ([string]$firstPr[0].html_url))
}

function Invoke-CiFailureIssueSync {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Repo,

        [Parameter(Mandatory)]
        [string] $WorkflowName,

        [Parameter(Mandatory)]
        [string] $RunUrl,

        [Parameter(Mandatory)]
        [string] $EventName,

        [Parameter(Mandatory)]
        [string] $FailedJobs,

        [Parameter(Mandatory)]
        [string] $FirstErrorLine,

        [string] $PrUrl = '',

        [switch] $DryRun
    )

    $errorHash = Get-CiErrorHash -WorkflowName $WorkflowName -FirstErrorLine $FirstErrorLine
    $shortError = (Remove-Credentials ($FirstErrorLine -replace '\s+', ' ')).Trim()
    if ($shortError.Length -gt 120) {
        $shortError = $shortError.Substring(0, 120)
    }

    $title = "fix: CI failure in $WorkflowName — $shortError [$errorHash]"
    $lines = @(
        '## CI failure detected',
        '',
        "- Workflow: $WorkflowName",
        "- Run URL: $RunUrl"
    )

    if ($EventName -eq 'pull_request' -and -not [string]::IsNullOrWhiteSpace($PrUrl)) {
        $lines += "- PR URL: $PrUrl"
    }

    $lines += @(
        "- Failed jobs: $FailedJobs",
        "- First error line: $FirstErrorLine"
    )
    $body = Remove-Credentials ($lines -join [Environment]::NewLine)

    $labelArgs = @('label', 'create', 'ci-failure', '--repo', $Repo, '--color', 'B60205', '--description', 'Automated CI failure report', '--force')
    if ($DryRun) {
        Write-Host "[DryRun] gh $($labelArgs -join ' ')"
    } else {
        [void](Invoke-GhCommand -Arguments $labelArgs -AllowFailure)
    }

    $existingArgs = @('issue', 'list', '--repo', $Repo, '--label', 'ci-failure', '--state', 'open', '--search', "[$errorHash] in:title", '--json', 'number', '--jq', '.[0].number // empty')
    $existingResult = Invoke-GhCommand -Arguments $existingArgs -AllowFailure
    $existingIssue = if ($existingResult.ExitCode -eq 0) { $existingResult.Output.Trim() } else { '' }

    if (-not [string]::IsNullOrWhiteSpace($existingIssue) -and $existingIssue -match '^\d+$') {
        $comment = "still failing — $RunUrl"
        if ($DryRun) {
            Write-Host "[DryRun] gh issue comment $existingIssue --repo $Repo --body '$comment'"
        } else {
            [void](Invoke-GhCommand -Arguments @('issue', 'comment', $existingIssue, '--repo', $Repo, '--body', $comment))
        }
        return
    }

    if ($DryRun) {
        Write-Host "[DryRun] gh issue create --repo $Repo --title '$title' --labels squad,type:bug,priority:p1,ci-failure"
        Write-Host "[DryRun] Body:"
        Write-Host $body
        return
    }

    $createResult = Invoke-GhCommand -Arguments @(
        'issue', 'create',
        '--repo', $Repo,
        '--title', $title,
        '--body', $body,
        '--label', 'squad',
        '--label', 'type:bug',
        '--label', 'priority:p1',
        '--label', 'ci-failure'
    ) -AllowFailure

    if ($createResult.ExitCode -ne 0) {
        $retryExisting = Invoke-GhCommand -Arguments $existingArgs -AllowFailure
        $retryIssue = if ($retryExisting.ExitCode -eq 0) { $retryExisting.Output.Trim() } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($retryIssue) -and $retryIssue -match '^\d+$') {
            [void](Invoke-GhCommand -Arguments @('issue', 'comment', $retryIssue, '--repo', $Repo, '--body', "still failing — $RunUrl") -AllowFailure)
            return
        }

        throw "Failed to create or reconcile ci-failure issue for hash [$errorHash]: $($createResult.Output)"
    }
}

function Resolve-CiFailureDuplicates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Repo,

        [Parameter(Mandatory)]
        [string] $ErrorHash,

        [switch] $DryRun
    )

    $allMatchesArgs = @('issue', 'list', '--repo', $Repo, '--label', 'ci-failure', '--state', 'open', '--search', "[$ErrorHash] in:title", '--json', 'number,createdAt')
    $matchesResult = Invoke-GhCommand -Arguments $allMatchesArgs -AllowFailure
    if ($matchesResult.ExitCode -ne 0) {
        return
    }

    $matches = @($matchesResult.Output | ConvertFrom-Json | Sort-Object createdAt)
    if ($matches.Count -le 1) {
        return
    }

    $canonical = [string]$matches[0].number
    $duplicates = @($matches | Select-Object -Skip 1)
    foreach ($dup in $duplicates) {
        $dupNumber = [string]$dup.number
        if ($DryRun) {
            Write-Host "[DryRun] gh issue close $dupNumber --repo $Repo --comment 'Duplicate of #$canonical'"
            continue
        }

        [void](Invoke-GhCommand -Arguments @('issue', 'comment', $dupNumber, '--repo', $Repo, '--body', "Closing duplicate ci-failure issue in favor of #$canonical for hash [$ErrorHash].") -AllowFailure)
        [void](Invoke-GhCommand -Arguments @('issue', 'close', $dupNumber, '--repo', $Repo, '--comment', "Duplicate of #$canonical") -AllowFailure)
    }
}

function Invoke-WatchGithubActions {
    [CmdletBinding()]
    param(
        [switch] $DryRun
    )

    if ($env:SQUAD_WATCH_CI -ne '1') {
        return
    }

    $stateDir = Join-Path $PSScriptRoot '..\.squad\state'
    $stateFile = Join-Path $stateDir 'last-ci-scan.json'

    $lastScan = [DateTimeOffset]::MinValue
    $processedRunIds = [System.Collections.Generic.HashSet[string]]::new()
    if (Test-Path $stateFile) {
        $rawState = Get-Content $stateFile -Raw
        $state = $rawState | ConvertFrom-Json
        if ($state.PSObject.Properties.Name -contains 'lastScanUtc') {
            $lastScan = [DateTimeOffset]::Parse([string]$state.lastScanUtc)
        }
        if ($state.PSObject.Properties.Name -contains 'processedRunIds') {
            foreach ($id in @($state.processedRunIds)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$id)) {
                    [void]$processedRunIds.Add([string]$id)
                }
            }
        }
    }

    $repo = (Invoke-GhCommand -Arguments @('repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner')).Output.Trim()
    $defaultBranch = (Invoke-GhCommand -Arguments @('repo', 'view', '--json', 'defaultBranchRef', '--jq', '.defaultBranchRef.name')).Output.Trim()
    $runList = Invoke-GhCommand -Arguments @(
        'run', 'list',
        '--status', 'failure',
        '--limit', '10',
        '--json', 'databaseId,conclusion,name,headBranch,event,url,createdAt,headSha'
    )

    $runs = @($runList.Output | ConvertFrom-Json)
    $newRuns = @(
        $runs | Where-Object {
            $_.conclusion -eq 'failure' -and
            $_.name -ne 'CI failure watchdog' -and
            (
                ([string]$_.headBranch -eq $defaultBranch) -or
                ([string]$_.headBranch -like 'squad/*')
            ) -and
            -not $processedRunIds.Contains([string]$_.databaseId)
        }
    )

    foreach ($run in $newRuns) {
        $runId = [long]$run.databaseId
        $logResult = Invoke-GhCommand -Arguments @('run', 'view', $runId, '--log-failed') -AllowFailure
        $firstError = Get-FirstErrorLine -RawLog $logResult.Output
        $failedJobs = Get-FailedJobNames -RunId $runId
        $prUrl = ''
        if ([string]$run.event -eq 'pull_request') {
            $prUrl = Get-PrUrlForRun -Repo $repo -RunId $runId
        }

        Invoke-CiFailureIssueSync `
            -Repo $repo `
            -WorkflowName (Remove-Credentials ([string]$run.name)) `
            -RunUrl (Remove-Credentials ([string]$run.url)) `
            -EventName (Remove-Credentials ([string]$run.event)) `
            -PrUrl $prUrl `
            -FailedJobs $failedJobs `
            -FirstErrorLine $firstError `
            -DryRun:$DryRun

        $hash = Get-CiErrorHash -WorkflowName (Remove-Credentials ([string]$run.name)) -FirstErrorLine $firstError
        Resolve-CiFailureDuplicates -Repo $repo -ErrorHash $hash -DryRun:$DryRun

        [void]$processedRunIds.Add([string]$run.databaseId)
    }

    if (-not $DryRun) {
        New-Item -Path $stateDir -ItemType Directory -Force | Out-Null
        $processedList = @($processedRunIds | Select-Object -Last 200)
        $statePayload = @{
            lastScanUtc = (Get-Date).ToUniversalTime().ToString('o')
            processedRunIds = $processedList
        } | ConvertTo-Json -Depth 3
        $statePayload = Remove-Credentials $statePayload
        Set-Content -Path $stateFile -Value $statePayload -Encoding UTF8
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-WatchGithubActions -DryRun:$DryRun
}
