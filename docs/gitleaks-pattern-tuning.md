# Gitleaks pattern tuning for ADO scans

Use `-GitleaksConfigPath` to apply a local `.toml` config when running ADO repo secret scans.

## Secure defaults

- Default behavior uses gitleaks built-in rules.
- Custom config must be a local `.toml` file path.
- URLs are rejected.
- Keep `[extend] useDefault = true` unless you have a reviewed custom ruleset.
- If a config sets `[extend] useDefault = false` and has no custom `[[rules]]`, the scanner emits a High finding.

## Org-level allowlist strategy

1. Start from `templates/gitleaks-ado-allowlist.toml`.
2. Add allowlist entries for known non-secret patterns that are common across repos.
3. Store the reviewed file in a secure internal location and pass it to scans:

```powershell
.\Invoke-AzureAnalyzer.ps1 -AdoOrg "contoso" -IncludeTools 'ado-repos-secrets' -GitleaksConfigPath ".\templates\gitleaks-ado-allowlist.toml"
```

## Repo-level override strategy

1. Keep org-level defaults in a shared config.
2. Create a repo-specific config with only additional allowlist entries or custom `[[rules]]`.
3. Run per-repo scans with that config path.

## Safe tuning checklist

- Validate every allowlist with real findings before merge.
- Avoid broad regexes that hide secret-like values.
- Re-test after gitleaks upgrades.
- Treat the "Custom gitleaks config applied" Info finding as an audit signal.
