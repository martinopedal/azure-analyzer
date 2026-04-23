#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    $script:ManifestPath = Join-Path $script:RepoRoot 'AzureAnalyzer.psd1'
}

AfterAll {
    Remove-Module -Name AzureAnalyzer -Force -ErrorAction SilentlyContinue
}

Describe 'AzureAnalyzer module import and manifest integrity' {
    It 'imports AzureAnalyzer.psd1 without errors' {
        { Import-Module $script:ManifestPath -Force -ErrorAction Stop } | Should -Not -Throw
    }

    It 'exports expected public commands after import' {
        Import-Module $script:ManifestPath -Force -ErrorAction Stop
        $commands = Get-Command -Module AzureAnalyzer

        $commands.Name | Should -Contain 'Invoke-AzureAnalyzer'
        $commands.Name | Should -Contain 'New-HtmlReport'
        $commands.Name | Should -Contain 'New-MdReport'
    }

    It 'validates AzureAnalyzer.psd1 with Test-ModuleManifest' {
        { Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop } | Should -Not -Throw
        $manifest = Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop
        $manifest | Should -Not -BeNullOrEmpty
    }

    It 'exposes typed Invoke-AzureAnalyzer parameters via module command metadata' {
        Import-Module $script:ManifestPath -Force -ErrorAction Stop
        $command = Get-Command -Name Invoke-AzureAnalyzer -Module AzureAnalyzer

        $command.Parameters.Keys | Should -Contain 'SubscriptionId'
        $command.Parameters.Keys | Should -Contain 'OutputPath'
        $command.Parameters.Keys | Should -Contain 'IncludeTools'
        $command.Parameters.Keys | Should -Not -Contain 'Arguments'
    }

    It 'includes typed parameters in Invoke-AzureAnalyzer help syntax' {
        Import-Module $script:ManifestPath -Force -ErrorAction Stop
        $help = Get-Help -Name Invoke-AzureAnalyzer -Full
        $parameterNames = @($help.parameters.parameter | ForEach-Object { $_.name })

        $parameterNames | Should -Contain 'SubscriptionId'
        $parameterNames | Should -Contain 'OutputPath'
        $parameterNames | Should -Contain 'IncludeTools'
    }
}
