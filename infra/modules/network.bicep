param location string
param prefix string

var vnetName = '${prefix}-vnet-${uniqueString(resourceGroup().id)}'
var pipName = '${prefix}-agw-pip-${uniqueString(resourceGroup().id)}'
var appGwSubnetName = 'snet-appgw'
var appSvcIntegrationSubnetName = 'snet-appsvc-integration'
var privateEndpointSubnetName = 'snet-private-endpoints'

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.20.0.0/16'
      ]
    }
    subnets: [
      {
        name: appGwSubnetName
        properties: {
          addressPrefix: '10.20.1.0/24'
        }
      }

      // App Service VNET Integration subnet
      // Must be delegated to Microsoft.Web/serverFarms
      {
        name: appSvcIntegrationSubnetName
        properties: {
          addressPrefix: '10.20.2.0/24'
          delegations: [
            {
              name: 'delegation'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }

      // Private Endpoint subnet
      {
        name: privateEndpointSubnetName
        properties: {
          addressPrefix: '10.20.3.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

// Public IP for App Gateway
resource pip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: pipName
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

output vnetId string = vnet.id
output pipId string = pip.id
output pipAddress string = pip.properties.ipAddress
output appGwSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, appGwSubnetName)
output appServiceIntegrationSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, appSvcIntegrationSubnetName)
