# Infracost - Required Permissions

**Display name:** Infracost IaC Cost Estimation

**Scope:** repository | **Provider:** cli

Runs `infracost breakdown --path <dir> --format json` against Terraform and Bicep source before deployment. This is static IaC analysis and does not query Azure Resource Manager.

## Required permissions

| Surface | Requirement |
|---|---|
| Azure | None |
| Microsoft Graph | None |
| GitHub | Token only required when cloning a private GitHub repo (`GITHUB_TOKEN` or `GH_TOKEN` with Contents: Read) |
| ADO | `AZURE_DEVOPS_EXT_PAT` with Code: Read required only when cloning a private ADO repo |
| Local | None for local path mode |

## Local CLI requirement

`infracost` must be on PATH. The wrapper is auto-installable through the manifest installer (winget on Windows, brew on macOS).

## What it does NOT do

- No `terraform plan`, `terraform apply`, or Bicep deployment.
- No Azure write operations.
- No Git writes to target repositories.
