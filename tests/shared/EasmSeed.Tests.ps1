#Requires -Version 7.4
Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    . (Join-Path $script:RepoRoot 'modules' 'shared' 'EasmSeed.ps1')
}

Describe 'Get-EasmSeed' {

    Context 'in-memory seed hashtable' {
        It 'normalises and de-duplicates inputs' {
            $seed = Get-EasmSeed -Seed @{
                Domains = @('Example.com', 'example.com', 'test.org')
                Ips     = @('1.2.3.4', '1.2.3.4', '5.6.7.8')
                Cidrs   = @('10.0.0.0/8')
                Asns    = @('AS12345', '12345')
            }
            $seed.Domains | Should -Be @('example.com', 'test.org')
            $seed.Ips     | Should -Be @('1.2.3.4', '5.6.7.8')
            $seed.Cidrs   | Should -Be @('10.0.0.0/8')
            # Both AS-prefixed and bare are valid; lower-cased + sorted
            $seed.Asns.Count | Should -Be 2
            $seed.SourceCount | Should -Be 1
        }

        It 'discards malformed entries with a warning' {
            $seed = Get-EasmSeed -Seed @{
                Domains = @('valid.example.com', 'not-a-domain', '$(rm -rf /)')
                Ips     = @('1.2.3.4', '999.999.999.999', 'not-an-ip')
                Cidrs   = @('10.0.0.0/8', '10.0.0.0', '300.0.0.0/8')
                Asns    = @('AS12345', 'NOTANASN')
            } -WarningAction SilentlyContinue
            $seed.Domains | Should -Be @('valid.example.com')
            $seed.Ips     | Should -Be @('1.2.3.4')
            $seed.Cidrs   | Should -Be @('10.0.0.0/8')
            $seed.Asns    | Should -Be @('as12345')
        }

        It 'returns a deterministic SHA-256 hash for identical inputs' {
            $a = Get-EasmSeed -Seed @{ Domains = @('a.example.com', 'b.example.com'); Ips = @('1.2.3.4') }
            $b = Get-EasmSeed -Seed @{ Domains = @('B.example.com', 'a.example.com'); Ips = @('1.2.3.4') }
            $a.Hash | Should -Be $b.Hash
            $a.Hash.Length | Should -Be 64
        }

        It 'returns different hashes for different seeds' {
            $a = Get-EasmSeed -Seed @{ Domains = @('a.example.com') }
            $b = Get-EasmSeed -Seed @{ Domains = @('b.example.com') }
            $a.Hash | Should -Not -Be $b.Hash
        }
    }

    Context 'SeedFile JSON input' {
        It 'parses a JSON seed file' {
            $tmp = Join-Path $TestDrive 'easm-seed.json'
            @{ domains = @('x.example.com'); ips = @('8.8.8.8'); cidrs = @(); asns = @() } |
                ConvertTo-Json | Set-Content -Path $tmp -Encoding UTF8
            $seed = Get-EasmSeed -SeedFile $tmp
            $seed.Domains | Should -Be @('x.example.com')
            $seed.Ips     | Should -Be @('8.8.8.8')
            $seed.SourceCount | Should -Be 1
        }

        It 'warns and yields empty seed when SeedFile is missing' {
            $seed = Get-EasmSeed -SeedFile (Join-Path $TestDrive 'does-not-exist.json') -WarningAction SilentlyContinue
            @($seed.Domains).Count | Should -Be 0
            $seed.SourceCount      | Should -Be 0
        }

        It 'merges in-memory seed + SeedFile + ARG augmentation' {
            $tmp = Join-Path $TestDrive 'easm-seed-merge.json'
            @{ domains = @('file.example.com'); ips = @() } | ConvertTo-Json | Set-Content -Path $tmp -Encoding UTF8
            $seed = Get-EasmSeed -SeedFile $tmp `
                -Seed @{ Domains = @('mem.example.com') } `
                -ArgPublicIps @('1.2.3.4') `
                -VerifiedDomains @('entra.example.com')
            $seed.Domains | Should -Contain 'file.example.com'
            $seed.Domains | Should -Contain 'mem.example.com'
            $seed.Domains | Should -Contain 'entra.example.com'
            $seed.Ips     | Should -Contain '1.2.3.4'
            $seed.SourceCount | Should -Be 4
        }
    }

    Context 'security guard' {
        It 'discards a domain longer than 253 chars' {
            $long = ('a' * 250) + '.com'
            $seed = Get-EasmSeed -Seed @{ Domains = @($long, 'short.example.com') } -WarningAction SilentlyContinue
            $seed.Domains | Should -Be @('short.example.com')
        }

        It 'refuses domains containing shell metacharacters' {
            $seed = Get-EasmSeed -Seed @{ Domains = @('safe.example.com', 'evil;rm -rf /.example.com', 'inj`whoami`.example.com') } -WarningAction SilentlyContinue
            $seed.Domains | Should -Be @('safe.example.com')
        }
    }
}
