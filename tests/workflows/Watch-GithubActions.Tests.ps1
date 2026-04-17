Describe 'Watch-GithubActions.ps1 env gate' {
    BeforeAll {
        $script:ScriptPath = Join-Path $PSScriptRoot '..' '..' 'tools' 'Watch-GithubActions.ps1'
    }

    BeforeEach {
        Remove-Item Env:SQUAD_WATCH_CI -ErrorAction SilentlyContinue
        function global:gh {
            throw 'gh should not be invoked when SQUAD_WATCH_CI is not set to 1'
        }
    }

    AfterEach {
        Remove-Item Function:\gh -ErrorAction SilentlyContinue
        Remove-Item Env:SQUAD_WATCH_CI -ErrorAction SilentlyContinue
    }

    It 'returns without gh calls when SQUAD_WATCH_CI is disabled' {
        { & $script:ScriptPath } | Should -Not -Throw
    }
}
