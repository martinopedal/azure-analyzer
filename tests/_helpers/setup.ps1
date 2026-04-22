#Requires -Version 7.0
<#
.SYNOPSIS
    Common Pester suite bootstrap. Dot-source this from CI runners or any
    test harness that wants the azure-analyzer-recommended defaults applied.

.DESCRIPTION
    Sets AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS=1 so that any wrapper
    code path that lands on Write-MissingToolNotice (modules/shared/MissingTool.ps1)
    is silenced for the duration of the test run. This keeps Pester transcripts
    clean of "<tool> is not installed. Skipping..." noise that originates from
    real wrappers being exercised against runners that don't ship those CLIs.
    See issue #472. The wrapper-side fix is in PR #480 / #496; this is the
    belt-and-suspenders kill-switch.

    NOTE: env vars are process-scoped. The flag persists for the life of the
    pwsh session that dot-sources this file. CI runners are short-lived and
    rebuilt per job, so leakage is not a concern. Local developers who want
    to inherit the flag from this file should dot-source it from their own
    Pester wrapper, e.g.:

        . ./tests/_helpers/setup.ps1
        Invoke-Pester -Path ./tests -CI
#>

$env:AZURE_ANALYZER_SUPPRESS_TOOL_MISSING_WARNINGS = '1'
