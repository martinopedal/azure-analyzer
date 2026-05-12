# dnstwist - Required Permissions

**Display name:** DNSTwist (typosquat / homoglyph detection)

**Scope:** tenant | **Provider:** easm

DNSTwist generates DNS permutations (typo, homoglyph, bitsquatting, hyphenation, insertion, omission, repetition, replacement, subdomain, transposition, vowel-swap, addition, tld-swap) for each domain in the EASM seed bundle and reports any permutation whose DNS or HTTP record is currently registered. This surfaces typosquats and brand-impersonation candidates against the customer's own domains.

The wrapper is **passive-only**: it queries public DNS resolvers and HTTP banners, never the customer's Azure tenant. It runs against the EASM seed bundle built by `Get-EasmSeed` (operator `-EasmSeedFile` JSON merged with optional ARG / Entra augmentation supplied by the orchestrator).

## Required permissions

| Mode | Auth | Notes |
|---|---|---|
| Default (passive) | None | DNSTwist queries public DNS only. No customer credentials required. |

No Azure RBAC, Microsoft Graph, GitHub, or ADO scopes are required. DNSTwist does not authenticate to Microsoft.

## Local CLI requirement

`dnstwist` must be on PATH. Missing CLI causes the tool to skip with an install instruction (`pipx install dnstwist`, or `brew install dnstwist` on macOS).

## Seed input

The wrapper accepts a seed bundle from one of:

- `-Seed @{ Domains = @('contoso.com') }` (in-memory)
- `-SeedFile ./easm-seed.json` (`{ "domains": [...], "ips": [...], "cidrs": [...], "asns": [...] }`)
- The orchestrator's auto-built seed (ARG public IPs + Entra verified domains + operator overrides) when invoked through `Invoke-AzureAnalyzer`.

Inputs are validated against a conservative regex in `modules/shared/EasmSeed.ps1` so a malicious seed file cannot smuggle shell metacharacters into the dnstwist invocation.

## Security invariants

- HTTPS / DNS only. Outbound requests go to public DNS resolvers and (optionally) HTTP probes against discovered hostnames.
- 300 s timeout per dnstwist invocation via `Invoke-WithTimeout`.
- All wrapper output is scrubbed via `Remove-Credentials` before being persisted.
- DNSTwist does not require, store, or accept any API key.

DNSTwist is read-only; no write permissions anywhere.
