# Azure Functions PowerShell profile.
# Runs once per cold start. Authenticate with the Function App's managed
# identity so downstream Az calls (and the orchestrator) inherit the context.
#
# All persisted error text MUST pass through Remove-Credentials -- the
# orchestrator dot-sources modules/shared/Sanitize.ps1, but the profile may
# log before the orchestrator is loaded, so we provide a local fallback.

if (-not (Get-Command Remove-Credentials -ErrorAction SilentlyContinue)) {
    function Remove-Credentials { param ([string]$Text) return $Text }
}

if ($env:MSI_SECRET -or $env:IDENTITY_HEADER) {
    try {
        Disable-AzContextAutosave -Scope Process | Out-Null
        Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
        Write-Host "[profile] Connected to Azure with managed identity."
    } catch {
        $msg = Remove-Credentials "$_"
        Write-Warning "[profile] Managed-identity sign-in failed: $msg"
    }
}
