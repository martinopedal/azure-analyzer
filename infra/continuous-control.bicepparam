// continuous-control.bicepparam
// Example parameter values for the continuous-control Bicep template.
// Copy this file, fill in your values, and deploy with:
//
//   az deployment group create \
//     --resource-group <your-resource-group> \
//     --template-file infra/continuous-control.bicep \
//     --parameters @infra/continuous-control.bicepparam

using 'continuous-control.bicep'

// Required: base name for all resources (3-20 chars, lowercase alphanumeric + hyphens)
param appName = 'azure-analyzer-cc'

// Optional: override region (defaults to the resource group region)
// param location = 'westeurope'

// Optional: 'Y1' for Consumption (free tier, 10-min timeout) or 'EP1' for Premium Elastic
param planSku = 'Y1'

// Optional: subscription ID to scan (defaults to the deployment subscription)
// param scanSubscriptionId = '00000000-0000-0000-0000-000000000000'

// Optional: Entra tenant ID (defaults to the deployment tenant)
// param scanTenantId = '00000000-0000-0000-0000-000000000000'

// Set to true to provision a Log Analytics workspace + DCE + DCR for the findings sink
param deployLogAnalytics = false
