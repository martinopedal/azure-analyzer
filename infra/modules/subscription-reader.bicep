// modules/subscription-reader.bicep
// Creates a Reader role assignment at subscription scope for a given principal.
// Must be called as a module with scope: subscription() from the parent template.
targetScope = 'subscription'

@description('Principal ID (object ID) of the managed identity to assign Reader to.')
param principalId string

@description('GUID for the role assignment. Use guid() to generate a stable value.')
param roleAssignmentName string

var readerRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader
)

resource readerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: roleAssignmentName
  properties: {
    roleDefinitionId: readerRoleId
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

output roleAssignmentId string = readerAssignment.id