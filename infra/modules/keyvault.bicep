param location string
param prefix string

var keyVaultName = '${prefix}-kv-${uniqueString(resourceGroup().id)}'

// Create Key Vault for storing SSL certificates
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    tenantId: tenant().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    // Allow Azure services (like App Gateway) to access the Key Vault
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true
    accessPolicies: [
      // Access policy for App Gateway managed identity is added by appgw.bicep
    ]
  }
}

// Output Key Vault details for use in other modules
output keyVaultId string = keyVault.id
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
