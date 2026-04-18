#Requires -Version 7.4

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'modules\shared\Canonicalize.ps1')
}

Describe 'ConvertTo-CanonicalArmId' {
    It 'lowercases and trims trailing slash' {
        $raw = '/Subscriptions/ABC12345-6789-4ABC-8DEF-1234567890AB/ResourceGroups/rg/providers/Microsoft.Storage/storageAccounts/foo/'
        ConvertTo-CanonicalArmId -ArmId $raw | Should -Be '/subscriptions/abc12345-6789-4abc-8def-1234567890ab/resourcegroups/rg/providers/microsoft.storage/storageaccounts/foo'
    }

    It 'throws on empty input' {
        { ConvertTo-CanonicalArmId -ArmId '' } | Should -Throw
    }
}

Describe 'ConvertTo-CanonicalRepoId' {
    It 'strips protocol and .git suffix' {
        ConvertTo-CanonicalRepoId -RepoId 'https://github.com/Org/Repo.git' | Should -Be 'github.com/org/repo'
    }

    It 'throws on invalid input' {
        { ConvertTo-CanonicalRepoId -RepoId 'not-a-repo' } | Should -Throw
    }

    It 'accepts GHES enterprise host URL' {
        ConvertTo-CanonicalRepoId -RepoId 'https://github.contoso.com/Org/Repo' | Should -Be 'github.contoso.com/org/repo'
    }

    It 'accepts GHEC-DR host URL' {
        ConvertTo-CanonicalRepoId -RepoId 'github.eu.acme.com/team/project' | Should -Be 'github.eu.acme.com/team/project'
    }

    It 'strips .git suffix from enterprise URLs' {
        ConvertTo-CanonicalRepoId -RepoId 'https://github.contoso.com/Org/Repo.git' | Should -Be 'github.contoso.com/org/repo'
    }

    It 'handles git@ SSH syntax for enterprise hosts' {
        ConvertTo-CanonicalRepoId -RepoId 'git@github.contoso.com:Org/Repo.git' | Should -Be 'github.contoso.com/org/repo'
    }
}

Describe 'ConvertTo-CanonicalAdoId' {
    It 'normalizes ado identifiers' {
        ConvertTo-CanonicalAdoId -AdoId 'Org/Project/pipeline/42' | Should -Be 'ado://org/project/pipeline/42'
    }

    It 'handles dev.azure.com URLs' {
        $url = 'https://dev.azure.com/Org/Project/_build?definitionId=42'
        ConvertTo-CanonicalAdoId -AdoId $url | Should -Be 'ado://org/project/pipeline/42'
    }
}

Describe 'ConvertTo-CanonicalSpnId' {
    It 'normalizes appId values' {
        ConvertTo-CanonicalSpnId -SpnId 'appId:ABC12345-6789-4ABC-8DEF-1234567890AB' | Should -Be 'appId:abc12345-6789-4abc-8def-1234567890ab'
    }

    It 'resolves objectId values with lookup' {
        $lookup = @{ '11111111-1111-1111-1111-111111111111' = '22222222-2222-2222-2222-222222222222' }
        ConvertTo-CanonicalSpnId -SpnId 'objectId:11111111-1111-1111-1111-111111111111' -ObjectIdToAppId $lookup | Should -Be 'appId:22222222-2222-2222-2222-222222222222'
    }

    It 'preserves objectId values when lookup is unavailable' {
        ConvertTo-CanonicalSpnId -SpnId 'objectId:11111111-1111-1111-1111-111111111111' | Should -Be 'objectId:11111111-1111-1111-1111-111111111111'
    }
}

Describe 'ConvertTo-CanonicalEntityId' {
    It 'derives platform metadata' {
        $result = ConvertTo-CanonicalEntityId `
            -RawId 'https://github.com/Org/Repo' `
            -EntityType 'Repository'

        $result.Platform | Should -Be 'GitHub'
        $result.CanonicalId | Should -Be 'github.com/org/repo'
    }

    It 'throws on empty input' {
        { ConvertTo-CanonicalEntityId -RawId '' -EntityType 'Repository' } | Should -Throw
    }
}
