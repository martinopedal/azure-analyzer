# Contributing

This is a solo-maintained repository. Contributions are welcome but the maintainer reviews and merges everything.

## Process

1. Fork the repo
2. Create a branch: `git checkout -b feat/your-change`
3. Make your changes
4. Sign off your commit: `git commit -s -m "feat: describe your change"`
5. Open a pull request against `main`

## Adding a new tool

Adding a new assessment tool requires three components:

1. **Collector** (`modules/Invoke-{ToolName}.ps1`) -- wraps the tool and returns raw findings
2. **Normalizer** (`modules/normalizers/Normalize-{ToolName}.ps1`) -- converts raw output to schema v2 FindingRow format using `New-FindingRow` from `modules/shared/Schema.ps1`
3. **Manifest entry** (`tools/tool-manifest.json`) -- registers the tool for orchestration

See [docs/CONTRIBUTING-TOOLS.md](docs/CONTRIBUTING-TOOLS.md) for the full wrapper contract, normalizer template, and testing checklist.

## AI-assisted contributions

AI-assisted contributions are welcome. If you used an AI tool to generate or refactor code, disclose it in the PR description using the pull request template. The maintainer will verify correctness before merging.

## Commit sign-off

All commits must include a `Signed-off-by` trailer. Use `git commit -s` to add it automatically. This certifies that you wrote the contribution or have the right to submit it under the project license.

## Review

PRs are reviewed by the maintainer. There are no required reviewers beyond the maintainer. `enforce_admins` is enabled, so branch protection applies to everyone including the maintainer.
