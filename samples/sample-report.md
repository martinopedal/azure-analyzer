# Azure Analyzer Report - 2026-04-18 17:52 UTC

## Summary

| Metric | Count |
|---|---|
| Total findings | 33 |
| Non-compliant | 32 |
| Compliant | 1 |
| High severity | 15 |
| Medium severity | 13 |
| Low severity | 1 |
| Info | 1 |

### By source

| Source | Status | Findings | Non-compliant |
|---|---|---|---|
| Azure Quick Review | Success | 2 | 2 |
| Kubescape (AKS runtime posture) | Success | 2 | 2 |
| kube-bench (AKS node-level CIS compliance) | Success | 2 | 2 |
| Microsoft Defender for Cloud | Success | 2 | 2 |
| Falco (AKS runtime anomaly detection) | Success | 2 | 2 |
| Azure Cost (Consumption API) | Success | 2 | 1 |
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

### Container Security

| Title | Severity | Source | Compliant | Detail | Resource ID | Learn More |
|---|---|---|---|---|---|---|
| CIS 4.2.1: Kubelet anonymous authentication is enabled | High | kube-bench | No | Kubelet on node 'aks-nodepool1-12345678-vmss000000' allows anonymous authentication. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-aks/providers/Microsoft.ContainerService/managedClusters/aks-prod-apps/agentPools/nodepool1 | [https://www.cisecurity.org/benchmark/kubernetes](https://www.cisecurity.org/benchmark/kubernetes) |
| K8s pod runs with privileged escalation enabled | High | kubescape | No | Pod 'prod-api-7d8f9c4b-xkz2p' in namespace 'default' has allowPrivilegeEscalation=true. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-aks/providers/Microsoft.ContainerService/managedClusters/aks-prod-apps/namespaces/default/pods/prod-api-7d8f9c4b-xkz2p | [https://hub.armosec.io/docs/c-0016](https://hub.armosec.io/docs/c-0016) |
| Suspicious shell spawned in container | High | falco | No | Container 'api' in pod 'prod-api-7d8f9c4b-xkz2p' spawned an interactive shell (bash) at 2026-04-16 22:15:42 UTC. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-aks/providers/Microsoft.ContainerService/managedClusters/aks-prod-apps/namespaces/default/pods/prod-api-7d8f9c4b-xkz2p | [https://falco.org/docs/rules/default-macros/#shell_procs](https://falco.org/docs/rules/default-macros/#shell_procs) |
| CIS 4.2.6: RotateKubeletServerCertificate not enabled | Medium | kube-bench | No | Kubelet certificate auto-rotation is disabled on node 'aks-nodepool1-12345678-vmss000000'. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-aks/providers/Microsoft.ContainerService/managedClusters/aks-prod-apps/agentPools/nodepool1 | [https://www.cisecurity.org/benchmark/kubernetes](https://www.cisecurity.org/benchmark/kubernetes) |
| Container running as root user | Medium | kubescape | No | Container 'api' in pod 'prod-api-7d8f9c4b-xkz2p' runs as UID 0 (root). | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-aks/providers/Microsoft.ContainerService/managedClusters/aks-prod-apps/namespaces/default/pods/prod-api-7d8f9c4b-xkz2p | [https://hub.armosec.io/docs/c-0013](https://hub.armosec.io/docs/c-0013) |
| File opened in /etc directory by container process | Medium | falco | No | Container 'worker' in pod 'prod-worker-5c9a8b1d-qwer' opened /etc/passwd for write at 2026-04-16 22:18:14 UTC. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-aks/providers/Microsoft.ContainerService/managedClusters/aks-prod-apps/namespaces/default/pods/prod-worker-5c9a8b1d-qwer | [https://falco.org/docs/rules/default-macros/#write_etc_common](https://falco.org/docs/rules/default-macros/#write_etc_common) |

### Cost Optimization

| Title | Severity | Source | Compliant | Detail | Resource ID | Learn More |
|---|---|---|---|---|---|---|
| Top cost contributor: AKS cluster 'aks-prod-apps' ($4,231/month) | Info | azure-cost | Yes | AKS cluster 'aks-prod-apps' consumed $4,231 in the last 30 days, representing 38% of subscription spend. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-aks/providers/Microsoft.ContainerService/managedClusters/aks-prod-apps | [https://learn.microsoft.com/azure/aks/cost-analysis](https://learn.microsoft.com/azure/aks/cost-analysis) |
| Unattached Premium SSD disk incurring cost ($127/month) | Medium | azure-cost | No | Managed disk 'disk-orphaned-data' is unattached and has been billed $127 over the last 30 days. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-data/providers/Microsoft.Compute/disks/disk-orphaned-data | [https://learn.microsoft.com/azure/cost-management-billing/costs/cost-analysis-common-uses](https://learn.microsoft.com/azure/cost-management-billing/costs/cost-analysis-common-uses) |

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
| Defender for Storage not enabled | High | defender-for-cloud | No | Subscription 'prod-01' does not have Defender for Storage enabled. | /subscriptions/00000000-1111-2222-3333-444444444444 | [https://learn.microsoft.com/azure/defender-for-cloud/defender-for-storage-introduction](https://learn.microsoft.com/azure/defender-for-cloud/defender-for-storage-introduction) |
| Key Vault soft delete is disabled | High | azqr | No | Key Vault 'kv-prod-secrets' does not have soft delete enabled. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-sec/providers/Microsoft.KeyVault/vaults/kv-prod-secrets | [https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview](https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview) |
| Vulnerability assessment not configured on SQL servers | Medium | defender-for-cloud | No | SQL server 'sql-prod' has no vulnerability assessment configured. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-data/providers/Microsoft.Sql/servers/sql-prod | [https://learn.microsoft.com/azure/defender-for-cloud/sql-azure-vulnerability-assessment-overview](https://learn.microsoft.com/azure/defender-for-cloud/sql-azure-vulnerability-assessment-overview) |

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
| CIS 4.2.1: Kubelet anonymous authentication is enabled | kube-bench | Kubelet on node 'aks-nodepool1-12345678-vmss000000' allows anonymous authentication. | Set --anonymous-auth=false in kubelet configuration. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-aks/providers/Microsoft.ContainerService/managedClusters/aks-prod-apps/agentPools/nodepool1 | [https://www.cisecurity.org/benchmark/kubernetes](https://www.cisecurity.org/benchmark/kubernetes) |
| Classic (password-based) service connection in use | ado-connections | Service connection 'prod-deploy' authenticates with a client secret instead of workload identity federation. | Migrate the service connection to Workload Identity Federation (OIDC). | ado://contoso/Platform/serviceEndpoint/prod-deploy | [https://learn.microsoft.com/azure/devops/pipelines/release/configure-workload-identity](https://learn.microsoft.com/azure/devops/pipelines/release/configure-workload-identity) |
| Defender for Storage not enabled | defender-for-cloud | Subscription 'prod-01' does not have Defender for Storage enabled. | Enable Defender for Storage to detect anomalous storage activity and malware uploads. | /subscriptions/00000000-1111-2222-3333-444444444444 | [https://learn.microsoft.com/azure/defender-for-cloud/defender-for-storage-introduction](https://learn.microsoft.com/azure/defender-for-cloud/defender-for-storage-introduction) |
| EIDSCA.AG01: Security defaults disabled, no Conditional Access | maester | Tenant has security defaults off and fewer than 2 baseline CA policies. | Deploy baseline Conditional Access policies covering MFA, legacy auth block, and risky sign-ins. | tenant:11111111-2222-3333-4444-555555555555 | [https://maester.dev/docs/tests/EIDSCA.AG01](https://maester.dev/docs/tests/EIDSCA.AG01) |
| K8s pod runs with privileged escalation enabled | kubescape | Pod 'prod-api-7d8f9c4b-xkz2p' in namespace 'default' has allowPrivilegeEscalation=true. | Set allowPrivilegeEscalation=false in the pod security context. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-aks/providers/Microsoft.ContainerService/managedClusters/aks-prod-apps/namespaces/default/pods/prod-api-7d8f9c4b-xkz2p | [https://hub.armosec.io/docs/c-0016](https://hub.armosec.io/docs/c-0016) |
| Key Vault soft delete is disabled | azqr | Key Vault 'kv-prod-secrets' does not have soft delete enabled. | Enable soft delete on the Key Vault with a minimum retention of 7 days. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-sec/providers/Microsoft.KeyVault/vaults/kv-prod-secrets | [https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview](https://learn.microsoft.com/azure/key-vault/general/soft-delete-overview) |
| NSG allows SSH from any source | azqr | Network Security Group allows SSH (port 22) from any source address. | Restrict SSH access to specific IP ranges or use Azure Bastion. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-net/providers/Microsoft.Network/networkSecurityGroups/nsg-frontend | [https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview](https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview) |
| Owner role assigned to non-PIM eligible user | azgovviz | User 'alice@contoso.com' holds a permanent Owner assignment on subscription 'prod-01'. | Convert the permanent assignment to PIM-eligible with JIT activation. | /subscriptions/00000000-1111-2222-3333-444444444444 | [https://learn.microsoft.com/entra/id-governance/privileged-identity-management/pim-configure](https://learn.microsoft.com/entra/id-governance/privileged-identity-management/pim-configure) |
| Public IP without NSG association | alz-queries | Public IP 'pip-prod-lb' is attached to a NIC that has no associated NSG. | Attach an NSG to the NIC or subnet; deny inbound by default. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-net/providers/Microsoft.Network/publicIPAddresses/pip-prod-lb | [https://github.com/martinopedal/alz-graph-queries](https://github.com/martinopedal/alz-graph-queries) |
| Service principal with Owner role is also an ADO service connection | identity-correlator | SPN 'sp-prod-deploy' has Owner on subscription prod-01 AND is used by ADO service connection 'prod-deploy'. A compromised ADO pipeline would gain tenant-level control. | Split responsibilities: use one SPN for role management (User Access Administrator) and a separate, scoped SPN for deployments. | appId:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee |  |
| SQL Database has no active geo-replication | wara | SQL database 'sqldb-prod-orders' has no secondary replica configured. | Enable active geo-replication or failover groups for critical databases. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-data/providers/Microsoft.Sql/servers/sql-prod/databases/sqldb-prod-orders | [https://learn.microsoft.com/azure/azure-sql/database/active-geo-replication-overview](https://learn.microsoft.com/azure/azure-sql/database/active-geo-replication-overview) |
| Suspicious shell spawned in container | falco | Container 'api' in pod 'prod-api-7d8f9c4b-xkz2p' spawned an interactive shell (bash) at 2026-04-16 22:15:42 UTC. | Review container logs and investigate unauthorized shell access. Consider using read-only root filesystems. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-aks/providers/Microsoft.ContainerService/managedClusters/aks-prod-apps/namespaces/default/pods/prod-api-7d8f9c4b-xkz2p | [https://falco.org/docs/rules/default-macros/#shell_procs](https://falco.org/docs/rules/default-macros/#shell_procs) |

### Plan to fix (Medium, non-compliant)

| Title | Source | Detail | Resource ID | Learn More |
|---|---|---|---|---|
| AKS cluster has no SLA tier enabled | wara | AKS cluster 'aks-prod-apps' is running on the Free tier without uptime SLA. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-aks/providers/Microsoft.ContainerService/managedClusters/aks-prod-apps | [https://learn.microsoft.com/azure/aks/uptime-sla](https://learn.microsoft.com/azure/aks/uptime-sla) |
| Azure.VM.AvailabilityZone: VM not deployed to availability zone | psrule | Virtual machine 'vm-prod-web-01' has no availability zone assigned. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-web/providers/Microsoft.Compute/virtualMachines/vm-prod-web-01 | [https://azure.github.io/PSRule.Rules.Azure/](https://azure.github.io/PSRule.Rules.Azure/) |
| Built-in policy 'Audit VMs without Azure Monitor agent' not assigned | azgovviz | Recommended built-in policy is not assigned at the management group scope. | /providers/Microsoft.Management/managementGroups/contoso-root | [https://github.com/JulianHayward/Azure-MG-Sub-Governance-Reporting](https://github.com/JulianHayward/Azure-MG-Sub-Governance-Reporting) |
| CIS 4.2.6: RotateKubeletServerCertificate not enabled | kube-bench | Kubelet certificate auto-rotation is disabled on node 'aks-nodepool1-12345678-vmss000000'. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-aks/providers/Microsoft.ContainerService/managedClusters/aks-prod-apps/agentPools/nodepool1 | [https://www.cisecurity.org/benchmark/kubernetes](https://www.cisecurity.org/benchmark/kubernetes) |
| Container running as root user | kubescape | Container 'api' in pod 'prod-api-7d8f9c4b-xkz2p' runs as UID 0 (root). | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-aks/providers/Microsoft.ContainerService/managedClusters/aks-prod-apps/namespaces/default/pods/prod-api-7d8f9c4b-xkz2p | [https://hub.armosec.io/docs/c-0013](https://hub.armosec.io/docs/c-0013) |
| CVE-2024-28849 (follow-redirects) | trivy | follow-redirects leaks Proxy-Authorization header across hosts. File: package-lock.json. Installed: 1.15.5. Fixed: 1.15.6. | package-lock.json | [https://nvd.nist.gov/vuln/detail/CVE-2024-28849](https://nvd.nist.gov/vuln/detail/CVE-2024-28849) |
| File opened in /etc directory by container process | falco | Container 'worker' in pod 'prod-worker-5c9a8b1d-qwer' opened /etc/passwd for write at 2026-04-16 22:18:14 UTC. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-aks/providers/Microsoft.ContainerService/managedClusters/aks-prod-apps/namespaces/default/pods/prod-worker-5c9a8b1d-qwer | [https://falco.org/docs/rules/default-macros/#write_etc_common](https://falco.org/docs/rules/default-macros/#write_etc_common) |
| Orphaned service principal with active role assignment | identity-correlator | SPN 'sp-legacy-etl' still holds Contributor on rg-prod-data but the corresponding App Registration was deleted 47 days ago. | appId:ffffffff-0000-1111-2222-333333333333 |  |
| Pinned-Dependencies score 5/10 | scorecard | 3 GitHub Actions in .github/workflows are pinned by tag rather than SHA. | github.com/contoso/azure-landing-zone | [https://github.com/ossf/scorecard/blob/main/docs/checks.md#pinned-dependencies](https://github.com/ossf/scorecard/blob/main/docs/checks.md#pinned-dependencies) |
| Service connection grants Contributor at subscription scope | ado-connections | 'prod-deploy' has Contributor on the entire prod subscription. | ado://contoso/Platform/serviceEndpoint/prod-deploy | [https://learn.microsoft.com/azure/role-based-access-control/best-practices](https://learn.microsoft.com/azure/role-based-access-control/best-practices) |
| Unattached Premium SSD disk incurring cost ($127/month) | azure-cost | Managed disk 'disk-orphaned-data' is unattached and has been billed $127 over the last 30 days. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-data/providers/Microsoft.Compute/disks/disk-orphaned-data | [https://learn.microsoft.com/azure/cost-management-billing/costs/cost-analysis-common-uses](https://learn.microsoft.com/azure/cost-management-billing/costs/cost-analysis-common-uses) |
| unpinned-uses: action pinned by tag, not SHA | zizmor | File .github/workflows/release.yml references actions/upload-artifact@v4 instead of a 40-char SHA. | .github/workflows/release.yml | [https://woodruffw.github.io/zizmor/audits/#unpinned-uses](https://woodruffw.github.io/zizmor/audits/#unpinned-uses) |
| Vulnerability assessment not configured on SQL servers | defender-for-cloud | SQL server 'sql-prod' has no vulnerability assessment configured. | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-data/providers/Microsoft.Sql/servers/sql-prod | [https://learn.microsoft.com/azure/defender-for-cloud/sql-azure-vulnerability-assessment-overview](https://learn.microsoft.com/azure/defender-for-cloud/sql-azure-vulnerability-assessment-overview) |

### Track (Low/Info, non-compliant)

| Title | Severity | Source | Detail | Resource ID | Learn More |
|---|---|---|---|---|---|
| Resource missing required tag 'owner' | Low | alz-queries | 12 resources in subscription 'prod-01' are missing the required 'owner' tag. | /subscriptions/00000000-1111-2222-3333-444444444444 | [https://github.com/martinopedal/alz-graph-queries](https://github.com/martinopedal/alz-graph-queries) |


## Cross-Entity Correlation

The identity-correlator tool performs cross-platform correlation to surface high-risk combinations of permissions and access paths. Below is a worked example from this scan:

### Example: SPN with Owner role also used as ADO service connection

**Finding ID**: identity-correlator-001

**Entity**: Service Principal sp-prod-deploy (appId:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee)

**Correlation chain**:
1. **Entra ID**: SPN sp-prod-deploy exists in tenant 11111111-2222-3333-4444-555555555555
2. **Azure RBAC**: Same SPN holds **Owner** role on subscription prod-01 (/subscriptions/00000000-1111-2222-3333-444444444444)
3. **ADO Service Connection**: Same SPN is configured as the identity for ADO service connection prod-deploy in project Platform

**Risk amplification**: A single compromised ADO pipeline job gains:
- Full subscription Owner privileges (create/delete/modify any resource)
- Ability to assign roles to other identities (privilege escalation path)
- Access to Key Vaults, storage accounts, and all data in the subscription

**Remediation**: Split the SPN into two:
- **Deployment SPN**: Scoped to resource group level with Contributor role (no role assignment capability)
- **IAM SPN**: Separate identity with User Access Administrator role, used only for role management workflows

**Evidence sources**:
- ado-connections-001: Flags the service connection as password-based
- identity-correlator-001: Correlates SPN identity across Entra + Azure RBAC + ADO platforms
- azgovviz-002: Flags the Owner assignment as permanent (non-PIM)

This correlation pattern is invisible to single-tool scans. Only cross-platform analysis surfaces the blast radius.

## Risk Scoring and Prioritization

Azure-analyzer does not currently implement a numeric risk score per finding. Prioritization is driven by:

1. **Severity** (Critical > High > Medium > Low > Info) - assigned by each tool's normalizer based on impact
2. **Compliant flag** - non-compliant findings are surfaced in the Action Plan section
3. **Cross-entity correlation** - findings that span multiple platforms (e.g., identity-correlator results) are flagged for higher attention

**Future enhancement (planned)**: A risk score factoring in:
- Attack surface exposure (public IP + no NSG = higher risk than internal-only resource)
- Blast radius (Owner role on subscription > Contributor on single RG)
- Correlation multiplier (finding linked to other findings via entity ID)
- Time-to-exploit (CVE with public PoC > configuration drift)

For now, use the **Fix now** section (High severity, non-compliant) as your prioritization queue.

## Interactive Filters (HTML Report Only)

The HTML report (New-HtmlReport.ps1) includes interactive filter chips powered by client-side JavaScript. These filters are not available in the Markdown report but are described here for reference:

### Available filter categories

| Filter category | Values | Behavior |
|---|---|---|
| **Severity** | Critical, High, Medium, Low, Info | Multi-select: show findings matching ANY selected severity |
| **Source Tool** | azqr, psrule, azgovviz, alz-queries, wara, maester, scorecard, ado-connections, identity-correlator, zizmor, gitleaks, trivy, kubescape, kube-bench, defender-for-cloud, falco, azure-cost | Multi-select: show findings from ANY selected tool |
| **Compliant** | Compliant, Non-compliant | Toggle: filter by compliance status |
| **Category** | CI/CD Security, Container Security, Cost Optimization, Governance, Identity, Networking, Reliability, Secret Detection, Security, Supply Chain | Multi-select: show findings in ANY selected category |
| **Entity Type** (future) | AzureResource, ServicePrincipal, Repository, Workflow, Subscription, Tenant, etc. | Multi-select: show findings tagged with ANY selected entity type |

### Filter UI components

1. **Severity chips**: Color-coded buttons (red=Critical, orange=High, yellow=Medium, blue=Low, gray=Info)
2. **Source tool chips**: Color-coded per tool manifest (e.g., azqr=#1565c0, maester=#7b1fa2)
3. **Search box**: Free-text filter across Title, Detail, ResourceId, and Remediation fields
4. **Reset button**: Clears all active filters

### Implementation notes

- Filters use **OR** logic within a category (e.g., "High OR Critical")
- Filters use **AND** logic across categories (e.g., "High severity AND from azqr AND in category Security")
- Filter state is NOT persisted to URL hash in the current implementation (planned enhancement)
- All filtering is client-side; no server round-trip required

To see the interactive filters in action, generate the HTML report with:

```powershell
.\New-HtmlReport.ps1 -InputPath .\output\results.json -OutputPath .\output\report.html
```

Then open eport.html in a web browser.
