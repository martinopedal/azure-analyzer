# tests/fixtures/iac

Realistic, hand-curated fixtures used by the wrapper-level E2E coverage tests
for the IaC tools (#663 bicep-iac, #664 infracost, #665 terraform-iac).

| File                       | Used by                              | Purpose |
|----------------------------|--------------------------------------|---------|
| `main.bicep`               | `Invoke-IaCBicep.E2E.Tests.ps1`      | A Bicep file the adapter discovers via `Get-ChildItem -Filter *.bicep`. |
| `bicep-build-output.txt`   | `Invoke-IaCBicep.E2E.Tests.ps1`      | Realistic stderr from `bicep build` (BCP062 + BCP036 diagnostics) returned by the mocked `Invoke-WithTimeout`. |
| `main.tf`                  | `Invoke-IaCTerraform.E2E.Tests.ps1`  | A Terraform file the adapter discovers via `Get-ChildItem -Filter *.tf`. |
| `terraform-validate.json`  | `Invoke-IaCTerraform.E2E.Tests.ps1`  | `terraform validate -json` output with one error + one warning diagnostic. |
| `trivy-config.json`        | `Invoke-IaCTerraform.E2E.Tests.ps1`  | `trivy config --format json` output with one HIGH misconfiguration. |
| `infracost-breakdown.json` | `Invoke-Infracost.E2E.Tests.ps1`     | `infracost breakdown --format json` output with a baseline + diff. |

Every fixture is fully synthetic. No real subscription IDs, secrets, or
customer data are present. All values are scrubbed by `Remove-Credentials`
before being written to disk anyway, so the fixtures double as scrub test
inputs.
