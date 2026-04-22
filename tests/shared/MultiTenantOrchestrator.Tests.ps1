#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $script:Here = Split-Path $PSCommandPath -Parent
    $script:RepoRoot = Resolve-Path (Join-Path $script:Here '..' '..')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Sanitize.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'Errors.ps1')
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'MultiTenantOrchestrator.ps1')
}

Describe 'ConvertFrom-TenantConfig' {
    BeforeEach {
        $script:tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("mt-cfg-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:tmpDir -Force | Out-Null
    }
    AfterEach {
        if (Test-Path $script:tmpDir) { Remove-Item $script:tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'parses a valid JSON config file' {
        $cfg = @(
            @{ tenantId = '11111111-1111-1111-1111-111111111111'; subscriptionIds = @('22222222-2222-2222-2222-222222222222'); label = 'prod' }
            @{ tenantId = '33333333-3333-3333-3333-333333333333'; subscriptionIds = @(); label = 'dev' }
        )
        $path = Join-Path $script:tmpDir 'cfg.json'
        $cfg | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path -Encoding UTF8
        $result = ConvertFrom-TenantConfig -Path $path
        $result.Count | Should -Be 2
        $result[0].TenantId | Should -Be '11111111-1111-1111-1111-111111111111'
        $result[0].SubscriptionIds.Count | Should -Be 1
        $result[0].Label | Should -Be 'prod'
        $result[1].SubscriptionIds.Count | Should -Be 0
    }

    It 'normalizes a -TenantList array' {
        $r = ConvertFrom-TenantConfig -TenantList @('11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333333')
        $r.Count | Should -Be 2
        $r[0].Label | Should -Be '11111111-1111-1111-1111-111111111111'
        $r[0].SubscriptionIds.Count | Should -Be 0
    }

    It 'throws on invalid GUID' {
        $path = Join-Path $script:tmpDir 'bad.json'
        Set-Content -LiteralPath $path -Value '[{"tenantId":"not-a-guid","subscriptionIds":[]}]'
        { ConvertFrom-TenantConfig -Path $path } | Should -Throw -ExpectedMessage '*Invalid tenantId*'
    }

    It 'throws on duplicate tenantId' {
        $cfg = @(
            @{ tenantId = '11111111-1111-1111-1111-111111111111' }
            @{ tenantId = '11111111-1111-1111-1111-111111111111' }
        )
        $path = Join-Path $script:tmpDir 'dup.json'
        $cfg | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path
        { ConvertFrom-TenantConfig -Path $path } | Should -Throw -ExpectedMessage '*Duplicate*'
    }

    It 'throws on missing file' {
        { ConvertFrom-TenantConfig -Path (Join-Path $script:tmpDir 'nope.json') } | Should -Throw -ExpectedMessage '*not found*'
    }
}

Describe 'ConvertTo-ChildArgList' {
    It 'strips MultiTenant + CommonParameters and emits sorted flags' {
        $bound = @{
            TenantId      = 'ignored'
            SubscriptionId = 'ignored'
            OutputPath    = 'ignored'
            TenantConfig  = 'ignored'
            Tenants       = @('a')
            Verbose       = [System.Management.Automation.SwitchParameter]::new($true)
            Repository    = 'github.com/o/r'
        }
        $args = ConvertTo-ChildArgList -BoundParameters $bound -Override @{ TenantId = 't1'; OutputPath = 'C:\out' }
        $args | Should -Contain '-TenantId'
        $args | Should -Contain 't1'
        $args | Should -Contain '-OutputPath'
        $args | Should -Contain 'C:\out'
        $args | Should -Contain '-Repository'
        $args | Should -Not -Contain '-Verbose'
        $args | Should -Not -Contain '-TenantConfig'
        $args | Should -Not -Contain '-Tenants'
        $args | Should -Not -Contain '-SubscriptionId'   # original SubscriptionId stripped, no override
    }

    It 'round-trips switch params as bare flag' {
        $bound = @{ Incremental = [System.Management.Automation.SwitchParameter]::new($true) }
        $args = ConvertTo-ChildArgList -BoundParameters $bound
        ($args -join ' ') | Should -Be '-Incremental'
    }

    It 'omits switches when not present' {
        $bound = @{ Incremental = [System.Management.Automation.SwitchParameter]::new($false) }
        $args = ConvertTo-ChildArgList -BoundParameters $bound
        $args.Count | Should -Be 0
    }

    It 'expands array params to space-separated tokens' {
        $bound = @{ IncludeTools = @('alz-queries','azqr','psrule') }
        $args = ConvertTo-ChildArgList -BoundParameters $bound
        $args[0] | Should -Be '-IncludeTools'
        $args[1] | Should -Be 'alz-queries'
        $args[2] | Should -Be 'azqr'
        $args[3] | Should -Be 'psrule'
    }

    It 'omits null and empty values' {
        $bound = @{ Repository = ''; AdoOrg = $null; RepoPath = 'C:\repo' }
        $args = ConvertTo-ChildArgList -BoundParameters $bound
        $args | Should -Contain '-RepoPath'
        $args | Should -Not -Contain '-Repository'
        $args | Should -Not -Contain '-AdoOrg'
    }
}

Describe 'Invoke-MultiTenantScan' {
    BeforeEach {
        $script:tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("mt-run-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:tmpDir -Force | Out-Null
        $script:scriptPath = Join-Path $script:tmpDir 'fake-orchestrator.ps1'
        '# fake' | Set-Content -LiteralPath $script:scriptPath
        $script:tenants = @(
            [pscustomobject]@{ TenantId = '11111111-1111-1111-1111-111111111111'; SubscriptionIds = @('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'); Label = 'prod' }
            [pscustomobject]@{ TenantId = '22222222-2222-2222-2222-222222222222'; SubscriptionIds = @(); Label = 'fail-me' }
            [pscustomobject]@{ TenantId = '33333333-3333-3333-3333-333333333333'; SubscriptionIds = @('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'); Label = 'dev' }
        )
        $script:invocations = New-Object 'System.Collections.Generic.List[object]'
    }
    AfterEach {
        if (Test-Path $script:tmpDir) { Remove-Item $script:tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'isolates per-tenant OutputPath and forwards correct args' {
        $invocs = $script:invocations
        $runner = {
            param ($childScript, $childArgs, $childWorkDir, $childTimeout)
            $invocs.Add([pscustomobject]@{ Args = $childArgs; WorkDir = $childWorkDir }) | Out-Null
            @( @{ Severity = 'High'; Title = 'x' } ) | ConvertTo-Json -AsArray | Set-Content -LiteralPath (Join-Path $childWorkDir 'results.json')
            return [pscustomobject]@{ ExitCode = 0; Stderr = '' }
        }.GetNewClosure()

        $summary = Invoke-MultiTenantScan -Tenants $script:tenants -OutputPath $script:tmpDir `
            -ScriptPath $script:scriptPath -ForwardParams @{ Repository = 'github.com/o/r' } -Runner $runner

        $invocs.Count | Should -Be 3
        # Each invocation must carry -TenantId + -OutputPath, must NOT carry -TenantConfig/-Tenants.
        foreach ($i in $invocs) {
            $i.Args | Should -Contain '-TenantId'
            $i.Args | Should -Contain '-OutputPath'
            $i.Args | Should -Not -Contain '-TenantConfig'
            $i.Args | Should -Not -Contain '-Tenants'
        }
        $summary.Tenants.Count | Should -Be 3
        ($summary.Tenants | Where-Object Status -eq 'success').Count | Should -Be 3
    }

    It 'recovers from per-tenant failure and continues' {
        $invocs = $script:invocations
        $runner = {
            param ($childScript, $childArgs, $childWorkDir, $childTimeout)
            $tenantArg = $childArgs[ ($childArgs.IndexOf('-TenantId') + 1) ]
            $invocs.Add([pscustomobject]@{ TenantId = $tenantArg }) | Out-Null
            if ($tenantArg -eq '22222222-2222-2222-2222-222222222222') {
                return [pscustomobject]@{ ExitCode = 7; Stderr = 'Bearer eyJhbGciOiJSUzI1NiJ9.fake.signature leaked here' }
            }
            @( @{ Severity = 'Critical'; Title = 'y' } ) | ConvertTo-Json -AsArray | Set-Content -LiteralPath (Join-Path $childWorkDir 'results.json')
            return [pscustomobject]@{ ExitCode = 0; Stderr = '' }
        }.GetNewClosure()

        $summary = Invoke-MultiTenantScan -Tenants $script:tenants -OutputPath $script:tmpDir `
            -ScriptPath $script:scriptPath -Runner $runner

        # All three tenants must have been attempted.
        $invocs.Count | Should -Be 3
        $summary.Tenants[0].Status | Should -Be 'success'
        $summary.Tenants[1].Status | Should -Be 'failure'
        $summary.Tenants[1].ExitCode | Should -Be 7
        $summary.Tenants[2].Status | Should -Be 'success'
        # Sanitization: the bearer token must not survive into the summary.
        $summary.Tenants[1].Error | Should -Not -Match 'eyJhbGciOiJSUzI1NiJ9'
        $summary.Totals.Failed | Should -Be 1
        # Aggregate severity totals: 2 successful tenants each emitted 1 Critical finding.
        $summary.Totals.Critical | Should -Be 2
    }

    It 'writes multi-tenant-summary.json + .html to OutputPath' {
        $runner = {
            param ($childScript, $childArgs, $childWorkDir, $childTimeout)
            @( @{ Severity = 'Medium'; Title = 'z' } ) | ConvertTo-Json -AsArray | Set-Content -LiteralPath (Join-Path $childWorkDir 'results.json')
            return [pscustomobject]@{ ExitCode = 0; Stderr = '' }
        }
        $null = Invoke-MultiTenantScan -Tenants $script:tenants -OutputPath $script:tmpDir `
            -ScriptPath $script:scriptPath -Runner $runner

        Test-Path (Join-Path $script:tmpDir 'multi-tenant-summary.json') | Should -BeTrue
        Test-Path (Join-Path $script:tmpDir 'multi-tenant-summary.html') | Should -BeTrue
        $json = Get-Content (Join-Path $script:tmpDir 'multi-tenant-summary.json') -Raw | ConvertFrom-Json
        $json.SchemaVersion | Should -Be '1.0'
        $json.Tenants.Count | Should -Be 3
        $json.Totals.Medium | Should -Be 3
    }

    It 'handles tenant-only entries (no subscriptions) with a single child invocation' {
        $invocs = $script:invocations
        $runner = {
            param ($childScript, $childArgs, $childWorkDir, $childTimeout)
            $invocs.Add([pscustomobject]@{ Args = $childArgs }) | Out-Null
            return [pscustomobject]@{ ExitCode = 0; Stderr = '' }
        }.GetNewClosure()

        $tenantOnly = @([pscustomobject]@{ TenantId = '44444444-4444-4444-4444-444444444444'; SubscriptionIds = @(); Label = 'graph-only' })
        $null = Invoke-MultiTenantScan -Tenants $tenantOnly -OutputPath $script:tmpDir `
            -ScriptPath $script:scriptPath -Runner $runner

        $invocs.Count | Should -Be 1
        $invocs[0].Args | Should -Not -Contain '-SubscriptionId'
    }
}
