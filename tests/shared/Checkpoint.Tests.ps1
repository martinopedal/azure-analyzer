Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot\..\..\modules\shared\Checkpoint.ps1"
}

Describe 'Get-CheckpointKey' {
    It 'uses identity-correlator key for identity scope by default' {
        $key = Get-CheckpointKey -ScopeType Identity
        $key | Should -Be 'identity-correlator'
    }

    It 'sanitizes path-like values in scope keys' {
        $key = Get-CheckpointKey -ScopeType Repository -RepoSlug 'owner/..\repo'
        $key | Should -Be 'repo-owner___repo'
    }
}

Describe 'Save-Checkpoint / Get-Checkpoint roundtrip' {
    BeforeAll {
        $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "checkpoint-test-$([Guid]::NewGuid().ToString('N'))"
    }

    AfterAll {
        if (Test-Path $testDir) { Remove-Item $testDir -Recurse -Force }
    }

    It 'saves and retrieves a checkpoint correctly' {
        $result = [PSCustomObject]@{ Status = 'Complete'; FindingCount = 42 }
        $path = Save-Checkpoint -CheckpointDir $testDir -Tool 'psrule' -ScopeType Subscription -SubscriptionId 'sub-123' -Result $result
        $path | Should -Not -BeNullOrEmpty
        Test-Path $path | Should -BeTrue

        $loaded = Get-Checkpoint -CheckpointDir $testDir -Tool 'psrule' -ScopeType Subscription -SubscriptionId 'sub-123'
        $loaded | Should -Not -BeNull
        $loaded.Status | Should -Be 'Complete'
        $loaded.FindingCount | Should -Be 42
    }

    It 'returns null for missing checkpoint' {
        $loaded = Get-Checkpoint -CheckpointDir $testDir -Tool 'nonexistent' -ScopeType Tenant -TenantId 'tid-999'
        $loaded | Should -BeNull
    }

    It 'removes a checkpoint and returns true' {
        $result = [PSCustomObject]@{ Status = 'Done' }
        Save-Checkpoint -CheckpointDir $testDir -Tool 'removeme' -ScopeType Tenant -TenantId 'tid-remove' -Result $result
        $removed = Remove-Checkpoint -CheckpointDir $testDir -Tool 'removeme' -ScopeType Tenant -TenantId 'tid-remove'
        $removed | Should -BeTrue
        $loaded = Get-Checkpoint -CheckpointDir $testDir -Tool 'removeme' -ScopeType Tenant -TenantId 'tid-remove'
        $loaded | Should -BeNull
    }

    It 'uses atomic write (temp file does not persist)' {
        $result = [PSCustomObject]@{ Status = 'Atomic' }
        Save-Checkpoint -CheckpointDir $testDir -Tool 'atomic' -ScopeType Subscription -SubscriptionId 'sub-atomic' -Result $result
        $tempFiles = Get-ChildItem $testDir -Filter '*.tmp-*' -ErrorAction SilentlyContinue
        @($tempFiles).Count | Should -Be 0
    }
}

Describe 'Get-CheckpointPath traversal guard' {
    It 'sanitizes traversal attempts to stay within checkpoint dir' {
        $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "checkpoint-guard-$([Guid]::NewGuid().ToString('N'))"
        $null = New-Item -ItemType Directory -Path $testDir -Force
        try {
            $path = Get-CheckpointPath -CheckpointDir $testDir -Tool '..\..\etc' -ScopeKey 'passwd'
            # Traversal chars are sanitized — path must remain inside checkpoint dir
            $resolvedDir = [System.IO.Path]::GetFullPath($testDir)
            $path | Should -BeLike "$resolvedDir*"
            $path | Should -Not -BeLike '*..*..*'
        } finally {
            Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Get-CheckpointPath cross-platform separator' {
    It 'uses platform-native directory separator' {
        $testDir = Join-Path ([System.IO.Path]::GetTempPath()) "checkpoint-sep-$([Guid]::NewGuid().ToString('N'))"
        $null = New-Item -ItemType Directory -Path $testDir -Force
        try {
            $path = Get-CheckpointPath -CheckpointDir $testDir -Tool 'test' -ScopeKey 'scope'
            $path | Should -Not -BeNullOrEmpty
            $path | Should -BeLike "$testDir*"
        } finally {
            Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}


Describe 'Checkpoint reuse for incremental scans (#94)' {
    BeforeAll {
        $script:incDir = Join-Path ([System.IO.Path]::GetTempPath()) "checkpoint-inc-$([Guid]::NewGuid().ToString('N'))"
    }
    AfterAll {
        if (Test-Path $script:incDir) { Remove-Item $script:incDir -Recurse -Force }
    }

    It 'reloads a saved per-tool checkpoint as a cache hit on the next incremental run' {
        $cached = [PSCustomObject]@{
            RunMode      = 'Incremental'
            FindingCount = 12
            CompletedAt  = (Get-Date).ToUniversalTime().ToString('o')
        }
        Save-Checkpoint -CheckpointDir $script:incDir -Tool 'azqr' -ScopeType Subscription -SubscriptionId 'sub-inc-1' -Result $cached | Out-Null

        $loaded = Get-Checkpoint -CheckpointDir $script:incDir -Tool 'azqr' -ScopeType Subscription -SubscriptionId 'sub-inc-1'
        $loaded | Should -Not -BeNull
        $loaded.RunMode | Should -Be 'Incremental'
        $loaded.FindingCount | Should -Be 12
    }
}
