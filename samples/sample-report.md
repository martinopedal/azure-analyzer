# Azure Analyzer Report — 2026-04-16 22:35 UTC

## Summary

| Metric | Count |
|---|---|
| Total findings | 23 |
| Non-compliant | 23 |
| Compliant | 0 |
| High severity | 11 |
| Medium severity | 8 |
| Low severity | 1 |
| Info | 0 |

### By source

| Source | Status | Findings | Non-compliant |
|---|---|---|---|
| Azure Quick Review | Success | 2 | 2 |
| PSRule for Azure | Success | 2 | 2 |
| AzGovViz | Success | 2 | 2 |
| ALZ Resource Graph Queries | Success | 2 | 2 |
| Well-Architected Reliability Assessment | Success | 2 | 2 |
| Maester | Success | 2 | 2 |
| OpenSSF Scorecard | Success | 2 | 2 |
| ADO Service Connections | Success | 2 | 2 |
| Identity Correlator | Success | 2 | 2 |
| zizmor (Actions YAML Scanner) | Success | 2 | 2 |
| gitleaks (Secrets Scanner) | Success | 1 | 1 |
| Trivy Vulnerability Scanner | Success | 2 | 2 |

## Findings by category

### CI/CD Security

| Title | Severity | Source | Compliant | Detail | Resource ID | Learn More |
|---|---|---|---|---|---|---|
| template-injection: Workflow uses ${{ github.event.issue.title }} in run step | Critical | zizmor | No | File .github/workflows/triage.yml injects untrusted issue title directly into a shell command. | .github/workflows/triage.yml | [https://woodruffw.github.io/zizmor/audits/#template-injection](https://woodruffw.github.io/zizmor/audits/#template-injection) |
| unpinned-uses: action pinned by tag, not SHA | Medium | zizmor | No | File .github/workflows/release.yml references actions/upload-artifact@v4 instead of a 40-char SHA. | .github/workflows/release.yml | [https://woodruffw.github.io/zizmor/audits/#unpinned-uses](https://woodruffw.github.io/zizmor/audits/#unpinned-uses) |

### Governance

| Title | Severity | Source | Compliant | Detail | Resource ID | Learn More |
|---|---|---|---|---|---|---|
| Resource missing required tag 'owner' | Low | alz-queries | No | 12 resources in subscription 'prod-01' are missing the required 'owner' tag. | /subscriptions/00000000-1111-2222-3333-444444444444 | [https://github.com/martinopedal/alz-graph-queries](https://github.com/martinopedal/alz-graph-queries) |
| Built-in policy 'Audit VMs without Azure Monitor agent' not assigned | Medium | azgovviz | No | Recommended built-in policy is not assigned at the management group scope. | /providers/Microsoft.Management/managementGroups/contoso-root | [https://github.com/JulianHayward/Azure-MG-Sub-Governance-Reporting](https://github.com/JulianHayward/Azure-MG-Sub-Governance-Reporting) |

### Identity

| Title | Severity | Source | Compliant | Detail | Resource ID | Learn More |
|---|---|---|---|---|---|---|
| MT.1010: Breakglass accounts without MFA | Critical | maester | No | 2 of 2 breakglass accounts have no MFA registered. | tenant:11111111-2222-3333-4444-555555555555 | [https://maester.dev/docs/tests/MT.1010](https://maester.dev/docs/tests/MT.1010) |
| Classic (password-based) service connection in use | High | ado-connections | No | Service connection 'prod-deploy' authenticates with a client secret instead of workload identity federation. | ado://contoso/Platform/serviceEndpoint/prod-deploy | [https://learn.microsoft.com/azure/devops/pipelines/release/configure-workload-identity](https://learn.microsoft.com/azure/devops/pipelines/release/configure-workload-identity) |
| EIDSCA.AG01: Security defaults disabled, no Conditional Access | High | maester | No | Tenant has security defaults off and fewer than 2 baseline CA policies. | tenant:11111111-2222-3333-4444-555555555555 | [https://maester.dev/docs/tests/EIDSCA.AG01](https://maester.dev/docs/tests/EIDSCA.AG01) |
| Owner role assigned to non-PIM eligible user | High | azgovviz | No | User 'alice@contoso.com' holds a permanent Owner assignment on subscription 'prod-01'. | /subscriptions/00000000-1111-2222-3333-444444444444 | [https://learn.microsoft.com/entra/id-governance/privileged-identity-management/pim-configure](https://learn.microsoft.com/entra/id-governance/privileged-identity-management/pim-configure) |
| Service principal with Owner role is also an ADO service connection | High | identity-correlator | No | SPN 'sp-prod-deploy' has Owner on subscription prod-01 AND is used by ADO service connection 'prod-deploy'. A compromised ADO pipeline would gain tenant-level control. | appId:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee |  |
| Orphaned service principal with active role assignment | Medium | identity-correlator | No | SPN 'sp-legacy-etl' still holds Contributor on rg-prod-data but the corresponding App Registration was deleted 47 days ago. | appId:ffffffff-0000-1111-2222-333333333333 |  |
| Service connection grants Contributor at subscription scope | Medium | ado-connections | No | 'prod-deploy' has Contributor on the entire prod subscription. | ado://contoso/Platform/serviceEndpoint/prod-deploy | [https://learn.microsoft.com/azure/role-based-access-control/best-practices](https://learn.microsoft.com/azure/role-based-access-control/best-practices) |

### Networking

| Title | Severity | Source | Compliant | Detail | Resource ID | Learn More |
|---|---|---|---|---|---|---|
| NSG allows SSH from any source | High | azqr | No | Network Security Group allows SSH (port 22) from any source address. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-net/providers/Microsoft.Network/networkSecurityGroups/nsg-frontend | [https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview](https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview) |
| Public IP without NSG association | High | alz-queries | No | Public IP 'pip-prod-lb' is attached to a NIC that has no associated NSG. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-net/providers/Microsoft.Network/publicIPAddresses/pip-prod-lb | [https://github.com/martinopedal/alz-graph-queries](https://github.com/martinopedal/alz-graph-queries) |

### Reliability

| Title | Severity | Source | Compliant | Detail | Resource ID | Learn More |
|---|---|---|---|---|---|---|
| SQL Database has no active geo-replication | High | wara | No | SQL database 'sqldb-prod-orders' has no secondary replica configured. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-data/providers/Microsoft.Sql/servers/sql-prod/databases/sqldb-prod-orders | [https://learn.microsoft.com/azure/azure-sql/database/active-geo-replication-overview](https://learn.microsoft.com/azure/azure-sql/database/active-geo-replication-overview) |
| AKS cluster has no SLA tier enabled | Medium | wara | No | AKS cluster 'aks-prod-apps' is running on the Free tier without uptime SLA. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-aks/providers/Microsoft.ContainerService/managedClusters/aks-prod-apps | [https://learn.microsoft.com/azure/aks/uptime-sla](https://learn.microsoft.com/azure/aks/uptime-sla) |
| Azure.VM.AvailabilityZone: VM not deployed to availability zone | Medium | psrule | No | Virtual machine 'vm-prod-web-01' has no availability zone assigned. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-web/providers/Microsoft.Compute/virtualMachines/vm-prod-web-01 | [https://azure.github.io/PSRule.Rules.Azure/](https://azure.github.io/PSRule.Rules.Azure/) |

### Secret Detection

| Title | Severity | Source | Compliant | Detail | Resource ID | Learn More |
|---|---|---|---|---|---|---|
| AWS access key found in commit history | High | gitleaks | No | Rule 'aws-access-token' matched in file scripts/legacy-migrate.sh at line 14. Commit: 8a1f3c2. | scripts/legacy-migrate.sh | [https://github.com/gitleaks/gitleaks](https://github.com/gitleaks/gitleaks) |

### Security

| Title | Severity | Source | Compliant | Detail | Resource ID | Learn More |
|---|---|---|---|---|---|---|
| Azure.Storage.SecureTransfer: Storage account requires HTTPS | High | psrule | No | Storage account 'stprodlogs' allows unencrypted HTTP traffic. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-data/providers/Microsoft.Storage/storageAccounts/stprodlogs | [https://azure.github.io/PSRule.Rules.Azure/en/rules/Azure.Storage.SecureTransfer/](https://azure.github.io/PSRule.Rules.Azure/en/rules/Azure.Storage.SecureTransfer/) |
| Key Vault soft delete is disabled | High | azqr | No | Key Vault 'kv-prod-secrets' does not have soft delete enabled. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-sec/providers/Microsoft.KeyVault/vaults/kv-prod-secrets | [https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview](https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview) |

### Supply Chain

| Title | Severity | Source | Compliant | Detail | Resource ID | Learn More |
|---|---|---|---|---|---|---|
| CVE-2024-24790 (golang.org/x/net) | Critical | trivy | No | Parsing malformed IPv4-mapped IPv6 addresses in net/netip causes incorrect results. File: go.mod. Installed: 0.21.0. Fixed: 0.23.0. | go.mod | [https://nvd.nist.gov/vuln/detail/CVE-2024-24790](https://nvd.nist.gov/vuln/detail/CVE-2024-24790) |
| Branch-Protection score 3/10 | High | scorecard | No | Default branch 'main' allows force-push and does not require code review. | github.com/contoso/azure-landing-zone | [https://github.com/ossf/scorecard/blob/main/docs/checks.md#branch-protection](https://github.com/ossf/scorecard/blob/main/docs/checks.md#branch-protection) |
| CVE-2024-28849 (follow-redirects) | Medium | trivy | No | follow-redirects leaks Proxy-Authorization header across hosts. File: package-lock.json. Installed: 1.15.5. Fixed: 1.15.6. | package-lock.json | [https://nvd.nist.gov/vuln/detail/CVE-2024-28849](https://nvd.nist.gov/vuln/detail/CVE-2024-28849) |
| Pinned-Dependencies score 5/10 | Medium | scorecard | No | 3 GitHub Actions in .github/workflows are pinned by tag rather than SHA. | github.com/contoso/azure-landing-zone | [https://github.com/ossf/scorecard/blob/main/docs/checks.md#pinned-dependencies](https://github.com/ossf/scorecard/blob/main/docs/checks.md#pinned-dependencies) |

## Action plan

### Fix now (High, non-compliant)

| Title | Source | Detail | Remediation | Resource ID | Learn More |
|---|---|---|---|---|---|
| AWS access key found in commit history | gitleaks | Rule 'aws-access-token' matched in file scripts/legacy-migrate.sh at line 14. Commit: 8a1f3c2. | Rotate the exposed credential immediately and purge it from git history with git-filter-repo. | scripts/legacy-migrate.sh | [https://github.com/gitleaks/gitleaks](https://github.com/gitleaks/gitleaks) |
| Azure.Storage.SecureTransfer: Storage account requires HTTPS | psrule | Storage account 'stprodlogs' allows unencrypted HTTP traffic. | Set supportsHttpsTrafficOnly=true on the storage account. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-data/providers/Microsoft.Storage/storageAccounts/stprodlogs | [https://azure.github.io/PSRule.Rules.Azure/en/rules/Azure.Storage.SecureTransfer/](https://azure.github.io/PSRule.Rules.Azure/en/rules/Azure.Storage.SecureTransfer/) |
| Branch-Protection score 3/10 | scorecard | Default branch 'main' allows force-push and does not require code review. | Enable required reviews, linear history, and prohibit force-push on protected branches. | github.com/contoso/azure-landing-zone | [https://github.com/ossf/scorecard/blob/main/docs/checks.md#branch-protection](https://github.com/ossf/scorecard/blob/main/docs/checks.md#branch-protection) |
| Classic (password-based) service connection in use | ado-connections | Service connection 'prod-deploy' authenticates with a client secret instead of workload identity federation. | Migrate the service connection to Workload Identity Federation (OIDC). | ado://contoso/Platform/serviceEndpoint/prod-deploy | [https://learn.microsoft.com/azure/devops/pipelines/release/configure-workload-identity](https://learn.microsoft.com/azure/devops/pipelines/release/configure-workload-identity) |
| EIDSCA.AG01: Security defaults disabled, no Conditional Access | maester | Tenant has security defaults off and fewer than 2 baseline CA policies. | Deploy baseline Conditional Access policies covering MFA, legacy auth block, and risky sign-ins. | tenant:11111111-2222-3333-4444-555555555555 | [https://maester.dev/docs/tests/EIDSCA.AG01](https://maester.dev/docs/tests/EIDSCA.AG01) |
| Key Vault soft delete is disabled | azqr | Key Vault 'kv-prod-secrets' does not have soft delete enabled. | Enable soft delete on the Key Vault with a minimum retention of 7 days. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-sec/providers/Microsoft.KeyVault/vaults/kv-prod-secrets | [https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview](https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview) |
| NSG allows SSH from any source | azqr | Network Security Group allows SSH (port 22) from any source address. | Restrict SSH access to specific IP ranges or use Azure Bastion. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-net/providers/Microsoft.Network/networkSecurityGroups/nsg-frontend | [https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview](https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview) |
| Owner role assigned to non-PIM eligible user | azgovviz | User 'alice@contoso.com' holds a permanent Owner assignment on subscription 'prod-01'. | Convert the permanent assignment to PIM-eligible with JIT activation. | /subscriptions/00000000-1111-2222-3333-444444444444 | [https://learn.microsoft.com/entra/id-governance/privileged-identity-management/pim-configure](https://learn.microsoft.com/entra/id-governance/privileged-identity-management/pim-configure) |
| Public IP without NSG association | alz-queries | Public IP 'pip-prod-lb' is attached to a NIC that has no associated NSG. | Attach an NSG to the NIC or subnet; deny inbound by default. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-net/providers/Microsoft.Network/publicIPAddresses/pip-prod-lb | [https://github.com/martinopedal/alz-graph-queries](https://github.com/martinopedal/alz-graph-queries) |
| Service principal with Owner role is also an ADO service connection | identity-correlator | SPN 'sp-prod-deploy' has Owner on subscription prod-01 AND is used by ADO service connection 'prod-deploy'. A compromised ADO pipeline would gain tenant-level control. | Split responsibilities: use one SPN for role management (User Access Administrator) and a separate, scoped SPN for deployments. | appId:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee |  |
| SQL Database has no active geo-replication | wara | SQL database 'sqldb-prod-orders' has no secondary replica configured. | Enable active geo-replication or failover groups for critical databases. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-data/providers/Microsoft.Sql/servers/sql-prod/databases/sqldb-prod-orders | [https://learn.microsoft.com/azure/azure-sql/database/active-geo-replication-overview](https://learn.microsoft.com/azure/azure-sql/database/active-geo-replication-overview) |

### Plan to fix (Medium, non-compliant)

| Title | Source | Detail | Resource ID | Learn More |
|---|---|---|---|---|
| AKS cluster has no SLA tier enabled | wara | AKS cluster 'aks-prod-apps' is running on the Free tier without uptime SLA. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-aks/providers/Microsoft.ContainerService/managedClusters/aks-prod-apps | [https://learn.microsoft.com/azure/aks/uptime-sla](https://learn.microsoft.com/azure/aks/uptime-sla) |
| Azure.VM.AvailabilityZone: VM not deployed to availability zone | psrule | Virtual machine 'vm-prod-web-01' has no availability zone assigned. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-web/providers/Microsoft.Compute/virtualMachines/vm-prod-web-01 | [https://azure.github.io/PSRule.Rules.Azure/](https://azure.github.io/PSRule.Rules.Azure/) |
| Built-in policy 'Audit VMs without Azure Monitor agent' not assigned | azgovviz | Recommended built-in policy is not assigned at the management group scope. | /providers/Microsoft.Management/managementGroups/contoso-root | [https://github.com/JulianHayward/Azure-MG-Sub-Governance-Reporting](https://github.com/JulianHayward/Azure-MG-Sub-Governance-Reporting) |
| CVE-2024-28849 (follow-redirects) | trivy | follow-redirects leaks Proxy-Authorization header across hosts. File: package-lock.json. Installed: 1.15.5. Fixed: 1.15.6. | package-lock.json | [https://nvd.nist.gov/vuln/detail/CVE-2024-28849](https://nvd.nist.gov/vuln/detail/CVE-2024-28849) |
| Orphaned service principal with active role assignment | identity-correlator | SPN 'sp-legacy-etl' still holds Contributor on rg-prod-data but the corresponding App Registration was deleted 47 days ago. | appId:ffffffff-0000-1111-2222-333333333333 |  |
| Pinned-Dependencies score 5/10 | scorecard | 3 GitHub Actions in .github/workflows are pinned by tag rather than SHA. | github.com/contoso/azure-landing-zone | [https://github.com/ossf/scorecard/blob/main/docs/checks.md#pinned-dependencies](https://github.com/ossf/scorecard/blob/main/docs/checks.md#pinned-dependencies) |
| Service connection grants Contributor at subscription scope | ado-connections | 'prod-deploy' has Contributor on the entire prod subscription. | ado://contoso/Platform/serviceEndpoint/prod-deploy | [https://learn.microsoft.com/azure/role-based-access-control/best-practices](https://learn.microsoft.com/azure/role-based-access-control/best-practices) |
| unpinned-uses: action pinned by tag, not SHA | zizmor | File .github/workflows/release.yml references actions/upload-artifact@v4 instead of a 40-char SHA. | .github/workflows/release.yml | [https://woodruffw.github.io/zizmor/audits/#unpinned-uses](https://woodruffw.github.io/zizmor/audits/#unpinned-uses) |

### Track (Low/Info, non-compliant)

| Title | Severity | Source | Detail | Resource ID | Learn More |
|---|---|---|---|---|---|
| Resource missing required tag 'owner' | Low | alz-queries | 12 resources in subscription 'prod-01' are missing the required 'owner' tag. | /subscriptions/00000000-1111-2222-3333-444444444444 | [https://github.com/martinopedal/alz-graph-queries](https://github.com/martinopedal/alz-graph-queries) |
