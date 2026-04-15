# Azure Analyzer Report — 2026-04-15 21:22 UTC

## Summary

| Metric | Count |
|---|---|
| Total findings | 18 |
| Non-compliant | 12 |
| Compliant | 6 |
| High severity | 5 |
| Medium severity | 5 |
| Low severity | 2 |
| Info | 6 |

### By source

| Source | Findings | Non-compliant |
|---|---|---|
| alz-queries | 4 | 2 |
| azgovviz | 3 | 2 |
| azqr | 3 | 2 |
| psrule | 4 | 3 |
| wara | 4 | 3 |

## Findings by category

### Compute

| Title | Severity | Source | Compliant | Detail | Resource ID | Learn More |
|---|---|---|---|---|---|---|
| Virtual machine scale set uses latest OS image | Info | alz-queries | Yes | VMSS is using the latest patched Ubuntu 22.04 LTS image | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-compute/providers/Microsoft.Compute/virtualMachineScaleSets/vmss-web-frontend |  |
| Virtual machine does not use managed disks | Medium | psrule | No | VM uses unmanaged disks which lack built-in redundancy and simplified management | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-compute/providers/Microsoft.Compute/virtualMachines/vm-app-backend-01 | [https://learn.microsoft.com/en-us/azure/virtual-machines/managed-disks-overview](https://learn.microsoft.com/en-us/azure/virtual-machines/managed-disks-overview) |

### Identity

| Title | Severity | Source | Compliant | Detail | Resource ID | Learn More |
|---|---|---|---|---|---|---|
| Subscription has Owner role assigned to external guest user | High | azgovviz | No | Guest user external-vendor@outlook.com has Owner role on subscription | /subscriptions/00000000-1111-2222-3333-444444444444 | [https://learn.microsoft.com/en-us/azure/role-based-access-control/role-assignments-external-users](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-assignments-external-users) |
| Managed identity used for Key Vault access | Info | alz-queries | Yes | Application uses managed identity instead of service principal secrets for Key Vault access | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-security/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-app-keyvault |  |

### Networking

| Title | Severity | Source | Compliant | Detail | Resource ID | Learn More |
|---|---|---|---|---|---|---|
| NSG has no inbound rules restricting SSH access | High | azqr | No | Network Security Group allows SSH (port 22) from any source address | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-networking/providers/Microsoft.Network/networkSecurityGroups/nsg-frontend | [https://learn.microsoft.com/en-us/azure/virtual-network/network-security-groups-overview](https://learn.microsoft.com/en-us/azure/virtual-network/network-security-groups-overview) |
| Public IP addresses found without DDoS protection | High | alz-queries | No | 3 public IP addresses are not protected by Azure DDoS Protection Standard | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-networking/providers/Microsoft.Network/publicIPAddresses/pip-appgw-frontend | [https://learn.microsoft.com/en-us/azure/ddos-protection/ddos-protection-overview](https://learn.microsoft.com/en-us/azure/ddos-protection/ddos-protection-overview) |
| Load balancer health probe is correctly configured | Info | wara | Yes | Standard Load Balancer has custom health probe on /health endpoint | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-networking/providers/Microsoft.Network/loadBalancers/lb-api-prod |  |
| AKS cluster does not use Azure CNI networking | Medium | psrule | No | Cluster uses kubenet instead of Azure CNI, limiting network policy support | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-aks/providers/Microsoft.ContainerService/managedClusters/aks-prod-001 | [https://learn.microsoft.com/en-us/azure/aks/configure-azure-cni](https://learn.microsoft.com/en-us/azure/aks/configure-azure-cni) |

### Reliability

| Title | Severity | Source | Compliant | Detail | Resource ID | Learn More |
|---|---|---|---|---|---|---|
| App Service plan has only 1 instance | High | wara | No | Production App Service plan has a single instance, creating a single point of failure | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-web/providers/Microsoft.Web/serverFarms/asp-api-prod | [https://learn.microsoft.com/en-us/azure/app-service/overview-hosting-plans](https://learn.microsoft.com/en-us/azure/app-service/overview-hosting-plans) |
| Cosmos DB account does not have multi-region writes enabled | Low | wara | No | Cosmos DB account is configured with single-region writes, limiting write availability during regional outages | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-data/providers/Microsoft.DocumentDB/databaseAccounts/cosmos-orders-prod | [https://learn.microsoft.com/en-us/azure/cosmos-db/how-to-multi-master](https://learn.microsoft.com/en-us/azure/cosmos-db/how-to-multi-master) |
| Diagnostic settings not configured for App Service | Low | psrule | No | App Service does not have diagnostic settings configured for Log Analytics | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-web/providers/Microsoft.Web/sites/app-api-gateway | [https://learn.microsoft.com/en-us/azure/app-service/troubleshoot-diagnostic-logs](https://learn.microsoft.com/en-us/azure/app-service/troubleshoot-diagnostic-logs) |
| Azure Cache for Redis has no geo-replication configured | Medium | wara | No | Redis cache is deployed in a single region without geo-replication for DR | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-cache/providers/Microsoft.Cache/redis/redis-session-prod | [https://learn.microsoft.com/en-us/azure/azure-cache-for-redis/cache-how-to-geo-replication](https://learn.microsoft.com/en-us/azure/azure-cache-for-redis/cache-how-to-geo-replication) |

### Security

| Title | Severity | Source | Compliant | Detail | Resource ID | Learn More |
|---|---|---|---|---|---|---|
| Key Vault soft delete is disabled | High | azqr | No | Key Vault does not have soft delete enabled, risking permanent data loss | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-security/providers/Microsoft.KeyVault/vaults/kv-prod-secrets | [https://learn.microsoft.com/en-us/azure/key-vault/general/soft-delete-overview](https://learn.microsoft.com/en-us/azure/key-vault/general/soft-delete-overview) |
| Azure SQL Database TDE is enabled | Info | psrule | Yes | Transparent Data Encryption is enabled on the SQL Database | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-data/providers/Microsoft.Sql/servers/sql-prod-east/databases/db-orders |  |
| Tag policy inheritance is correctly configured | Info | azgovviz | Yes | Tag inheritance policy is assigned and enforced across subscriptions | /providers/Microsoft.Management/managementGroups/mg-root |  |
| No Azure Policy assigned at management group scope | Medium | azgovviz | No | Management group 'mg-platform' has zero policy assignments, leaving governance gaps | /providers/Microsoft.Management/managementGroups/mg-platform | [https://learn.microsoft.com/en-us/azure/governance/policy/overview](https://learn.microsoft.com/en-us/azure/governance/policy/overview) |

### Storage

| Title | Severity | Source | Compliant | Detail | Resource ID | Learn More |
|---|---|---|---|---|---|---|
| Storage account uses HTTPS-only transport | Info | azqr | Yes | Storage account correctly enforces HTTPS-only connections | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-data/providers/Microsoft.Storage/storageAccounts/stproddata001 |  |
| Storage account allows public blob access | Medium | alz-queries | No | Storage account has AllowBlobPublicAccess set to true | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-data/providers/Microsoft.Storage/storageAccounts/stprodlogs002 | [https://learn.microsoft.com/en-us/azure/storage/blobs/anonymous-read-access-prevent](https://learn.microsoft.com/en-us/azure/storage/blobs/anonymous-read-access-prevent) |

## Action plan

### Fix now (High, non-compliant)

| Title | Source | Detail | Remediation | Resource ID | Learn More |
|---|---|---|---|---|---|
| App Service plan has only 1 instance | wara | Production App Service plan has a single instance, creating a single point of failure | Scale out to at least 2 instances and enable zone redundancy | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-web/providers/Microsoft.Web/serverFarms/asp-api-prod | [https://learn.microsoft.com/en-us/azure/app-service/overview-hosting-plans](https://learn.microsoft.com/en-us/azure/app-service/overview-hosting-plans) |
| Key Vault soft delete is disabled | azqr | Key Vault does not have soft delete enabled, risking permanent data loss | Enable soft delete on the Key Vault via portal or CLI | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-security/providers/Microsoft.KeyVault/vaults/kv-prod-secrets | [https://learn.microsoft.com/en-us/azure/key-vault/general/soft-delete-overview](https://learn.microsoft.com/en-us/azure/key-vault/general/soft-delete-overview) |
| NSG has no inbound rules restricting SSH access | azqr | Network Security Group allows SSH (port 22) from any source address | Restrict SSH access to specific IP ranges or use Azure Bastion. See https://learn.microsoft.com/en-us/azure/virtual-network/network-security-groups-overview | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-networking/providers/Microsoft.Network/networkSecurityGroups/nsg-frontend | [https://learn.microsoft.com/en-us/azure/virtual-network/network-security-groups-overview](https://learn.microsoft.com/en-us/azure/virtual-network/network-security-groups-overview) |
| Public IP addresses found without DDoS protection | alz-queries | 3 public IP addresses are not protected by Azure DDoS Protection Standard | Enable DDoS Protection Standard on the virtual network or use DDoS IP protection | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-networking/providers/Microsoft.Network/publicIPAddresses/pip-appgw-frontend | [https://learn.microsoft.com/en-us/azure/ddos-protection/ddos-protection-overview](https://learn.microsoft.com/en-us/azure/ddos-protection/ddos-protection-overview) |
| Subscription has Owner role assigned to external guest user | azgovviz | Guest user external-vendor@outlook.com has Owner role on subscription | Remove Owner from guest accounts; use scoped Contributor or custom roles instead | /subscriptions/00000000-1111-2222-3333-444444444444 | [https://learn.microsoft.com/en-us/azure/role-based-access-control/role-assignments-external-users](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-assignments-external-users) |

### Plan to fix (Medium, non-compliant)

| Title | Source | Detail | Resource ID | Learn More |
|---|---|---|---|---|
| AKS cluster does not use Azure CNI networking | psrule | Cluster uses kubenet instead of Azure CNI, limiting network policy support | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-aks/providers/Microsoft.ContainerService/managedClusters/aks-prod-001 | [https://learn.microsoft.com/en-us/azure/aks/configure-azure-cni](https://learn.microsoft.com/en-us/azure/aks/configure-azure-cni) |
| Azure Cache for Redis has no geo-replication configured | wara | Redis cache is deployed in a single region without geo-replication for DR | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-cache/providers/Microsoft.Cache/redis/redis-session-prod | [https://learn.microsoft.com/en-us/azure/azure-cache-for-redis/cache-how-to-geo-replication](https://learn.microsoft.com/en-us/azure/azure-cache-for-redis/cache-how-to-geo-replication) |
| No Azure Policy assigned at management group scope | azgovviz | Management group 'mg-platform' has zero policy assignments, leaving governance gaps | /providers/Microsoft.Management/managementGroups/mg-platform | [https://learn.microsoft.com/en-us/azure/governance/policy/overview](https://learn.microsoft.com/en-us/azure/governance/policy/overview) |
| Storage account allows public blob access | alz-queries | Storage account has AllowBlobPublicAccess set to true | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-data/providers/Microsoft.Storage/storageAccounts/stprodlogs002 | [https://learn.microsoft.com/en-us/azure/storage/blobs/anonymous-read-access-prevent](https://learn.microsoft.com/en-us/azure/storage/blobs/anonymous-read-access-prevent) |
| Virtual machine does not use managed disks | psrule | VM uses unmanaged disks which lack built-in redundancy and simplified management | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-compute/providers/Microsoft.Compute/virtualMachines/vm-app-backend-01 | [https://learn.microsoft.com/en-us/azure/virtual-machines/managed-disks-overview](https://learn.microsoft.com/en-us/azure/virtual-machines/managed-disks-overview) |

### Track (Low/Info, non-compliant)

| Title | Severity | Source | Detail | Resource ID | Learn More |
|---|---|---|---|---|---|
| Cosmos DB account does not have multi-region writes enabled | Low | wara | Cosmos DB account is configured with single-region writes, limiting write availability during regional outages | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-data/providers/Microsoft.DocumentDB/databaseAccounts/cosmos-orders-prod | [https://learn.microsoft.com/en-us/azure/cosmos-db/how-to-multi-master](https://learn.microsoft.com/en-us/azure/cosmos-db/how-to-multi-master) |
| Diagnostic settings not configured for App Service | Low | psrule | App Service does not have diagnostic settings configured for Log Analytics | /subscriptions/00000000-1111-2222-3333-444444444444/resourceGroups/rg-prod-web/providers/Microsoft.Web/sites/app-api-gateway | [https://learn.microsoft.com/en-us/azure/app-service/troubleshoot-diagnostic-logs](https://learn.microsoft.com/en-us/azure/app-service/troubleshoot-diagnostic-logs) |
