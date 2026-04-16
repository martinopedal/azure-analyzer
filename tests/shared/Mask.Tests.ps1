#Requires -Version 7.4

BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\modules\shared\Mask.ps1')
}

Describe 'ConvertTo-MaskedId' {
    It 'masks appId values' {
        $id = '12345678-1234-1234-1234-1234567890ab'
        $masked = ConvertTo-MaskedId -Id $id -Type 'appId'
        $masked | Should -Be '1234****-****-****-****-********90ab'
    }

    It 'masks objectId values' {
        $id = 'abcd5678-1234-1234-1234-1234567890ef'
        $masked = ConvertTo-MaskedId -Id $id -Type 'objectId'
        $masked | Should -Be 'abcd****-****-****-****-********90ef'
    }

    It 'redacts tenantId values' {
        $id = 'tenant-raw-value'
        ConvertTo-MaskedId -Id $id -Type 'tenantId' | Should -Be '[tenant-id]'
    }

    It 'bypasses masking when IncludeSensitiveDetails is set' {
        $id = '12345678-1234-1234-1234-1234567890ab'
        ConvertTo-MaskedId -Id $id -Type 'appId' -IncludeSensitiveDetails | Should -Be $id
    }

    It 'returns null inputs as null' {
        ConvertTo-MaskedId -Id $null -Type 'appId' | Should -Be $null
    }
}
