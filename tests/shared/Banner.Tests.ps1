#Requires -Version 7.4

BeforeAll {
    . (Join-Path $PSScriptRoot '..' '..' 'modules' 'shared' 'Banner.ps1')
}

Describe 'Get-AzureAnalyzerVersion' {
    It 'reads ModuleVersion from the project manifest' {
        $version = Get-AzureAnalyzerVersion
        $version | Should -Match '^\d+\.\d+\.\d+'
    }

    It 'returns unknown when the manifest is missing' {
        $missing = Join-Path $TestDrive 'no-such-manifest.psd1'
        Get-AzureAnalyzerVersion -ManifestPath $missing | Should -Be 'unknown'
    }
}

Describe 'Write-AzureAnalyzerBanner' {
    BeforeEach {
        Mock -CommandName Write-Host -MockWith { }
    }

    It 'prints the banner by default' {
        Write-AzureAnalyzerBanner -Version '9.9.9'
        Should -Invoke Write-Host -Times 1
    }

    It 'is suppressed when -NoBanner is passed' {
        Write-AzureAnalyzerBanner -NoBanner -Version '9.9.9'
        Should -Invoke Write-Host -Times 0 -Exactly
    }

    It 'is suppressed when -Quiet is passed' {
        Write-AzureAnalyzerBanner -Quiet -Version '9.9.9'
        Should -Invoke Write-Host -Times 0 -Exactly
    }

    It 'is suppressed when AZUREANALYZER_NO_BANNER env var is set' {
        $prev = $env:AZUREANALYZER_NO_BANNER
        try {
            $env:AZUREANALYZER_NO_BANNER = '1'
            Write-AzureAnalyzerBanner -Version '9.9.9'
            Should -Invoke Write-Host -Times 0 -Exactly
        } finally {
            if ($null -eq $prev) {
                Remove-Item Env:AZUREANALYZER_NO_BANNER -ErrorAction SilentlyContinue
            } else {
                $env:AZUREANALYZER_NO_BANNER = $prev
            }
        }
    }

    It 'omits color codes when NO_COLOR is set' {
        $prev = $env:NO_COLOR
        try {
            $env:NO_COLOR = '1'
            Write-AzureAnalyzerBanner -Version '9.9.9'
            Should -Invoke Write-Host -Times 0 -ParameterFilter { $null -ne $ForegroundColor }
        } finally {
            if ($null -eq $prev) {
                Remove-Item Env:NO_COLOR -ErrorAction SilentlyContinue
            } else {
                $env:NO_COLOR = $prev
            }
        }
    }

    It 'uses color when NO_COLOR is not set' {
        $prev = $env:NO_COLOR
        try {
            Remove-Item Env:NO_COLOR -ErrorAction SilentlyContinue
            Write-AzureAnalyzerBanner -Version '9.9.9'
            Should -Invoke Write-Host -Times 1 -ParameterFilter { $ForegroundColor -eq 'Cyan' }
        } finally {
            if ($null -ne $prev) { $env:NO_COLOR = $prev }
        }
    }

    It 'emits ASCII-only characters' {
        $sw = [System.IO.StringWriter]::new()
        Write-AzureAnalyzerBanner -Version '9.9.9' -Writer $sw
        $output = $sw.ToString()
        $output | Should -Match '9\.9\.9'
        foreach ($ch in $output.ToCharArray()) {
            [int]$ch | Should -BeLessThan 128
        }
    }
}
