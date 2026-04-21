#Requires -Version 7.4

BeforeAll {
    function Invoke-NormalizerWithContract {
        param(
            [string] $NormalizerName,
            [object] $ToolResult,
            [System.Collections.Generic.List[psobject]] $SharedCollector
        )

        $normCmd = Get-Command $NormalizerName -ErrorAction Stop
        $normParams = @{ ToolResult = $ToolResult }
        if (@($normCmd.Parameters.Keys) -contains 'EdgeCollector') {
            $normParams['EdgeCollector'] = $SharedCollector
        }
        return @(& $NormalizerName @normParams)
    }
}

Describe 'Normalizer EdgeCollector contract (Option B)' {
    It 'preserves legacy normalizer signatures without EdgeCollector' {
        function Test-LegacyNormalizer {
            param([object]$ToolResult)
            return @([pscustomobject]@{ Id = 'f1'; Source = 'legacy' })
        }

        $collector = [System.Collections.Generic.List[psobject]]::new()
        $rows = Invoke-NormalizerWithContract -NormalizerName 'Test-LegacyNormalizer' -ToolResult @{ Findings = @() } -SharedCollector $collector
        @($rows).Count | Should -Be 1
        $collector.Count | Should -Be 0
    }

    It 'passes shared collector when EdgeCollector param exists' {
        function Test-EdgeNormalizer {
            param(
                [object]$ToolResult,
                [System.Collections.Generic.List[psobject]]$EdgeCollector
            )
            $EdgeCollector.Add([pscustomobject]@{ EdgeId = 'e1'; Source = 'a'; Target = 'b'; Relation = 'DependsOn' }) | Out-Null
            return @([pscustomobject]@{ Id = 'f2'; Source = 'edge' })
        }

        $collector = [System.Collections.Generic.List[psobject]]::new()
        $rows = Invoke-NormalizerWithContract -NormalizerName 'Test-EdgeNormalizer' -ToolResult @{ Findings = @() } -SharedCollector $collector
        @($rows).Count | Should -Be 1
        $collector.Count | Should -Be 1
        $collector[0].Relation | Should -Be 'DependsOn'
    }
}
