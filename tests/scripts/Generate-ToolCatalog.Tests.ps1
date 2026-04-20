#requires -Version 7.0
#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

Describe 'Generate-ToolCatalog' {

    BeforeAll {
        $script:RepoRoot       = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:ScriptPath     = Join-Path $script:RepoRoot 'scripts\Generate-ToolCatalog.ps1'
        $script:ManifestPath   = Join-Path $script:RepoRoot 'tools\tool-manifest.json'
        $script:ConsumerPath   = Join-Path $script:RepoRoot 'docs\consumer\tool-catalog.md'
        $script:ContribPath    = Join-Path $script:RepoRoot 'docs\contributor\tool-catalog.md'
        $script:Manifest       = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
        $script:EnabledTools   = @($script:Manifest.tools | Where-Object { $_.enabled })
    }

    It 'script file exists' {
        Test-Path -LiteralPath $script:ScriptPath | Should -BeTrue
    }

    It 'manifest exposes at least one enabled tool' {
        $script:EnabledTools.Count | Should -BeGreaterThan 0
    }

    Context 'generation produces both catalog files' {
        BeforeAll {
            $script:TempConsumer = Join-Path ([System.IO.Path]::GetTempPath()) ("consumer-catalog-{0}.md" -f ([Guid]::NewGuid()))
            $script:TempContrib  = Join-Path ([System.IO.Path]::GetTempPath()) ("contributor-catalog-{0}.md" -f ([Guid]::NewGuid()))
            & $script:ScriptPath `
                -ManifestPath        $script:ManifestPath `
                -ConsumerOutPath     $script:TempConsumer `
                -ContributorOutPath  $script:TempContrib | Out-Null
        }

        AfterAll {
            Remove-Item -LiteralPath $script:TempConsumer -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $script:TempContrib  -Force -ErrorAction SilentlyContinue
        }

        It 'writes the consumer catalog' {
            Test-Path -LiteralPath $script:TempConsumer | Should -BeTrue
        }

        It 'writes the contributor catalog' {
            Test-Path -LiteralPath $script:TempContrib | Should -BeTrue
        }

        It 'consumer catalog has the GENERATED warning header' {
            (Get-Content -LiteralPath $script:TempConsumer -Raw) | Should -Match 'GENERATED FROM tools/tool-manifest\.json'
        }

        It 'contributor catalog has the GENERATED warning header' {
            (Get-Content -LiteralPath $script:TempContrib -Raw) | Should -Match 'GENERATED FROM tools/tool-manifest\.json'
        }

        It 'consumer catalog contains a row per enabled tool' {
            $content = Get-Content -LiteralPath $script:TempConsumer -Raw
            foreach ($tool in $script:EnabledTools) {
                $content | Should -Match ([regex]::Escape("``$($tool.name)``"))
            }
        }

        It 'contributor catalog contains a row per registered tool (enabled and disabled)' {
            $content = Get-Content -LiteralPath $script:TempContrib -Raw
            foreach ($tool in $script:Manifest.tools) {
                $content | Should -Match ([regex]::Escape("``$($tool.name)``"))
            }
        }

        It 'consumer catalog contains the scope reference table' {
            (Get-Content -LiteralPath $script:TempConsumer -Raw) | Should -Match '## Scope reference'
        }

        It 'contributor catalog has invocation and install sections' {
            $content = Get-Content -LiteralPath $script:TempContrib -Raw
            $content | Should -Match '## Invocation'
            $content | Should -Match '## Install \+ upstream'
        }

        It 'neither catalog contains an em dash' {
            $consumer = Get-Content -LiteralPath $script:TempConsumer -Raw
            $contrib  = Get-Content -LiteralPath $script:TempContrib  -Raw
            $consumer | Should -Not -Match ([char]0x2014)
            $contrib  | Should -Not -Match ([char]0x2014)
        }
    }

    Context 'idempotence and CheckOnly mode' {
        It 'is idempotent: running twice produces identical files' {
            $tempA = Join-Path ([System.IO.Path]::GetTempPath()) ("idem-a-{0}.md" -f ([Guid]::NewGuid()))
            $tempB = Join-Path ([System.IO.Path]::GetTempPath()) ("idem-b-{0}.md" -f ([Guid]::NewGuid()))
            try {
                & $script:ScriptPath -ManifestPath $script:ManifestPath -ConsumerOutPath $tempA -ContributorOutPath (Join-Path ([System.IO.Path]::GetTempPath()) "_c1.md") | Out-Null
                & $script:ScriptPath -ManifestPath $script:ManifestPath -ConsumerOutPath $tempB -ContributorOutPath (Join-Path ([System.IO.Path]::GetTempPath()) "_c2.md") | Out-Null
                (Get-FileHash -LiteralPath $tempA).Hash | Should -Be (Get-FileHash -LiteralPath $tempB).Hash
            } finally {
                Remove-Item -LiteralPath $tempA -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $tempB -Force -ErrorAction SilentlyContinue
            }
        }

        It 'CheckOnly succeeds against the committed catalogs' {
            $exitCode = 0
            try {
                & $script:ScriptPath -CheckOnly | Out-Null
                $exitCode = $LASTEXITCODE
            } catch {
                $exitCode = 99
            }
            $exitCode | Should -Be 0
        }

        It 'committed catalogs match the current manifest projection exactly' {
            $tempConsumer = Join-Path ([System.IO.Path]::GetTempPath()) ("verify-consumer-{0}.md" -f ([Guid]::NewGuid()))
            $tempContrib  = Join-Path ([System.IO.Path]::GetTempPath()) ("verify-contrib-{0}.md" -f ([Guid]::NewGuid()))
            try {
                & $script:ScriptPath `
                    -ManifestPath $script:ManifestPath `
                    -ConsumerOutPath $tempConsumer `
                    -ContributorOutPath $tempContrib | Out-Null

                $committedConsumer = (Get-Content -LiteralPath $script:ConsumerPath -Raw) -replace "`r`n", "`n"
                $generatedConsumer = (Get-Content -LiteralPath $tempConsumer -Raw) -replace "`r`n", "`n"
                $committedContrib  = (Get-Content -LiteralPath $script:ContribPath -Raw) -replace "`r`n", "`n"
                $generatedContrib  = (Get-Content -LiteralPath $tempContrib -Raw) -replace "`r`n", "`n"

                $committedConsumer | Should -Be $generatedConsumer
                $committedContrib  | Should -Be $generatedContrib
            } finally {
                Remove-Item -LiteralPath $tempConsumer -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $tempContrib -Force -ErrorAction SilentlyContinue
            }
        }

        It 'CheckOnly fails when the committed file is stale' {
            $tempStale = Join-Path ([System.IO.Path]::GetTempPath()) ("stale-{0}.md" -f ([Guid]::NewGuid()))
            $tempContrib = Join-Path ([System.IO.Path]::GetTempPath()) ("stale-contrib-{0}.md" -f ([Guid]::NewGuid()))
            try {
                Set-Content -LiteralPath $tempStale -Value "stale content" -NoNewline
                Set-Content -LiteralPath $tempContrib -Value "stale content" -NoNewline
                & $script:ScriptPath -CheckOnly -ConsumerOutPath $tempStale -ContributorOutPath $tempContrib 2>&1 | Out-Null
                $LASTEXITCODE | Should -Be 1
            } finally {
                Remove-Item -LiteralPath $tempStale -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $tempContrib -Force -ErrorAction SilentlyContinue
                $global:LASTEXITCODE = 0
            }
        }
    }

    AfterAll {
        $global:LASTEXITCODE = 0
    }
}
