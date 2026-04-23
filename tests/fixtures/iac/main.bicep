// Realistic Bicep fixture for E2E wrapper coverage (#663).
// Intentionally references an undefined symbol so a mocked
// `bicep build` can simulate a BCP062 diagnostic without
// needing the real Bicep CLI on the test runner.
param location string = resourceGroup().location

resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountNameInvalid
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
}
