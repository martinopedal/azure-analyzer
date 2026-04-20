// continuous-control.bicep
// Provisions the azure-analyzer continuous-control Function App and supporting
// infrastructure. Deploy with:
//   az deployment group create \
//     --resource-group <rg> \
//     --template-file infra/continuous-control.bicep \
//     --parameters @infra/continuous-control.bicepparam

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Base name used to derive resource names. 3-20 lowercase alphanumeric + hyphens.')
@minLength(3)
@maxLength(20)
param appName string

@description('App Service Plan SKU. Y1 = Consumption (10 min timeout). EP1 = Premium Elastic (no timeout).')
@allowed(['Y1', 'EP1'])
param planSku string = 'Y1'

@description('Target subscription ID that the Function App will scan. Defaults to the deployment subscription.')
param scanSubscriptionId string = subscription().subscriptionId

@description('Entra tenant ID. Defaults to the deployment tenant.')
param scanTenantId string = tenant().tenantId

@description('When true, provisions a Log Analytics workspace, Data Collection Endpoint, and Data Collection Rule for the findings sink.')
param deployLogAnalytics bool = false

@description('GUID for the Reader role assignment on the MI at subscription scope. Change to rotate or create a second assignment.')
param readerRoleAssignmentName string = guid(subscription().subscriptionId, appName, 'reader-mi')

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------

// Storage names: 3-24 chars, lowercase alphanumeric only
var storageName = 'st${take(uniqueString(resourceGroup().id, appName), 22)}'

// Well-known Azure built-in role definition IDs
var readerRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader
)
var monitoringMetricsPublisherRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '3913510d-42f4-4e42-8a64-420c390055eb' // Monitoring Metrics Publisher
)

// ---------------------------------------------------------------------------
// User-assigned Managed Identity
// ---------------------------------------------------------------------------

resource userMI 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${appName}-mi'
  location: location
}

// ---------------------------------------------------------------------------
// Reader role at subscription scope (scope-escape to subscription)
// ---------------------------------------------------------------------------

resource readerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: subscription()
  name: readerRoleAssignmentName
  properties: {
    roleDefinitionId: readerRoleId
    principalId: userMI.properties.principalId
    principalType: 'ServicePrincipal'
    description: 'azure-analyzer continuous-control: Reader for scan MI'
  }
}

// ---------------------------------------------------------------------------
// Storage Account (Function App state)
// ---------------------------------------------------------------------------

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
  }
}

// ---------------------------------------------------------------------------
// App Service Plan
// ---------------------------------------------------------------------------

resource appPlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: '${appName}-plan'
  location: location
  sku: {
    name: planSku
    tier: planSku == 'EP1' ? 'ElasticPremium' : 'Dynamic'
  }
  kind: 'functionapp'
  properties: {
    reserved: false // Windows worker
  }
}

// ---------------------------------------------------------------------------
// Optional: Log Analytics Workspace
// ---------------------------------------------------------------------------

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = if (deployLogAnalytics) {
  name: '${appName}-law'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

// Custom table: AzureAnalyzerFindings_CL
resource findingsTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = if (deployLogAnalytics) {
  parent: logAnalytics
  name: 'AzureAnalyzerFindings_CL'
  properties: {
    schema: {
      name: 'AzureAnalyzerFindings_CL'
      columns: [
        { name: 'TimeGenerated', type: 'datetime' }
        { name: 'FindingId', type: 'string' }
        { name: 'Severity', type: 'string' }
        { name: 'Title', type: 'string' }
        { name: 'EntityType', type: 'string' }
        { name: 'EntityId', type: 'string' }
        { name: 'ToolName', type: 'string' }
        { name: 'Platform', type: 'string' }
        { name: 'SubscriptionId', type: 'string' }
        { name: 'Compliant', type: 'boolean' }
      ]
    }
    retentionInDays: 30
    plan: 'Analytics'
  }
}

// Custom table: AzureAnalyzerEntities_CL
resource entitiesTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = if (deployLogAnalytics) {
  parent: logAnalytics
  name: 'AzureAnalyzerEntities_CL'
  properties: {
    schema: {
      name: 'AzureAnalyzerEntities_CL'
      columns: [
        { name: 'TimeGenerated', type: 'datetime' }
        { name: 'EntityId', type: 'string' }
        { name: 'EntityType', type: 'string' }
        { name: 'Platform', type: 'string' }
        { name: 'DisplayName', type: 'string' }
        { name: 'SubscriptionId', type: 'string' }
      ]
    }
    retentionInDays: 30
    plan: 'Analytics'
  }
}

// ---------------------------------------------------------------------------
// Optional: Data Collection Endpoint
// ---------------------------------------------------------------------------

resource dce 'Microsoft.Insights/dataCollectionEndpoints@2022-06-01' = if (deployLogAnalytics) {
  name: '${appName}-dce'
  location: location
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// ---------------------------------------------------------------------------
// Optional: Data Collection Rule
// ---------------------------------------------------------------------------

resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' = if (deployLogAnalytics) {
  name: '${appName}-dcr'
  location: location
  properties: {
    dataCollectionEndpointId: deployLogAnalytics ? dce.id : null
    streamDeclarations: {
      'Custom-AzureAnalyzerFindings': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'FindingId', type: 'string' }
          { name: 'Severity', type: 'string' }
          { name: 'Title', type: 'string' }
          { name: 'EntityType', type: 'string' }
          { name: 'EntityId', type: 'string' }
          { name: 'ToolName', type: 'string' }
          { name: 'Platform', type: 'string' }
          { name: 'SubscriptionId', type: 'string' }
          { name: 'Compliant', type: 'boolean' }
        ]
      }
      'Custom-AzureAnalyzerEntities': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'EntityId', type: 'string' }
          { name: 'EntityType', type: 'string' }
          { name: 'Platform', type: 'string' }
          { name: 'DisplayName', type: 'string' }
          { name: 'SubscriptionId', type: 'string' }
        ]
      }
    }
    destinations: {
      logAnalytics: [
        {
          name: 'law-destination'
          workspaceResourceId: deployLogAnalytics ? logAnalytics.id : ''
        }
      ]
    }
    dataFlows: [
      {
        streams: ['Custom-AzureAnalyzerFindings']
        destinations: ['law-destination']
        transformKql: 'source'
        outputStream: 'Custom-AzureAnalyzerFindings_CL'
      }
      {
        streams: ['Custom-AzureAnalyzerEntities']
        destinations: ['law-destination']
        transformKql: 'source'
        outputStream: 'Custom-AzureAnalyzerEntities_CL'
      }
    ]
  }
  dependsOn: [
    findingsTable
    entitiesTable
  ]
}

// Monitoring Metrics Publisher on the DCR so the MI can POST ingestion data
resource metricsPublisherAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployLogAnalytics) {
  scope: dcr
  name: guid(appName, 'metrics-publisher-mi')
  properties: {
    roleDefinitionId: monitoringMetricsPublisherRoleId
    principalId: userMI.properties.principalId
    principalType: 'ServicePrincipal'
    description: 'azure-analyzer continuous-control: MI writes findings to DCR'
  }
}

// ---------------------------------------------------------------------------
// Function App
// ---------------------------------------------------------------------------

// Build the app settings list. Conditional sink settings are included always
// (empty string disables the sink) so the same app settings array works for
// both deployLogAnalytics=true and deployLogAnalytics=false.
var baseStorageConnStr = 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'

resource functionApp 'Microsoft.Web/sites@2023-01-01' = {
  name: appName
  location: location
  kind: 'functionapp'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userMI.id}': {}
    }
  }
  properties: {
    serverFarmId: appPlan.id
    httpsOnly: true
    siteConfig: {
      powerShellVersion: '7.4'
      use32BitWorkerProcess: false
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: [
        { name: 'AzureWebJobsStorage', value: baseStorageConnStr }
        { name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING', value: baseStorageConnStr }
        { name: 'WEBSITE_CONTENTSHARE', value: toLower(appName) }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'powershell' }
        // User-assigned MI client ID so Az module picks up the right identity
        { name: 'AZURE_CLIENT_ID', value: userMI.properties.clientId }
        // Scan targets
        { name: 'AZURE_ANALYZER_SUBSCRIPTION_ID', value: scanSubscriptionId }
        { name: 'AZURE_ANALYZER_TENANT_ID', value: scanTenantId }
        // Log Analytics sink (empty = sink disabled)
        { name: 'DCE_ENDPOINT', value: deployLogAnalytics ? dce.properties.logsIngestion.endpoint : '' }
        { name: 'DCR_IMMUTABLE_ID', value: deployLogAnalytics ? dcr.properties.immutableId : '' }
        { name: 'FINDINGS_STREAM', value: 'Custom-AzureAnalyzerFindings' }
        { name: 'ENTITIES_STREAM', value: 'Custom-AzureAnalyzerEntities' }
      ]
    }
  }
  dependsOn: [
    readerAssignment
  ]
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output functionAppName string = functionApp.name
output functionAppHostname string = functionApp.properties.defaultHostName
output managedIdentityClientId string = userMI.properties.clientId
output managedIdentityPrincipalId string = userMI.properties.principalId
output storageAccountName string = storageAccount.name
output logAnalyticsWorkspaceId string = deployLogAnalytics ? logAnalytics.id : ''
output dceEndpoint string = deployLogAnalytics ? dce.properties.logsIngestion.endpoint : ''
output dcrImmutableId string = deployLogAnalytics ? dcr.properties.immutableId : ''
