param location string
param prefix string
param appInsightsConnectionString string
param tenantId string
param clientAppId string
param apiAudience string
param publicMcpBaseUrl string
param requiredRole string = 'MCP.ReadWrite'
param requiredScope string = 'mcp.access'
// param vnetIntegrationSubnetId string = '' // future

var planName = '${prefix}-asp-${uniqueString(resourceGroup().id)}'
var webName  = '${prefix}-app-${uniqueString(resourceGroup().id)}'

// Extract app ID from api://appId format for audience array
var appId = replace(apiAudience, 'api://', '')

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  sku: {
    name: 'P1v3'
    tier: 'PremiumV3'
    capacity: 1
  }
  properties: {
    reserved: true // Linux
  }
}

resource site 'Microsoft.Web/sites@2023-12-01' = {
  name: webName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'DOTNETCORE|10.0'
      alwaysOn: true
      appSettings: [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsightsConnectionString
        }
        {
          name: 'ApplicationInsightsAgent_EXTENSION_VERSION'
          value: '~3'
        }
        {
          name: 'XDT_MicrosoftApplicationInsights_Mode'
          value: 'recommended'
        }
        {
          name: 'AzureAd__Instance'
          value: environment().authentication.loginEndpoint
        }
        {
          name: 'AzureAd__TenantId'
          value: tenantId
        }
        {
          name: 'AzureAd__ClientId'
          value: clientAppId
        }
        {
          name: 'AzureAd__Audience__0'
          value: apiAudience
        }
        {
          name: 'AzureAd__Audience__1'
          value: '00000002-0000-0000-c000-000000000000'
        }
        {
          name: 'AzureAd__RequiredRole'
          value: requiredRole
        }
        {
          name: 'AzureAd__RequiredScope'
          value: requiredScope
        }
        {
          name: 'AzureAd__EnableAuth'
          value: 'true'
        }
        {
          name: 'AzureAd__Authority'
          value: '${environment().authentication.loginEndpoint}/common/v2.0'
        }
        {
          name: 'PublicMcpBaseUrl'
          value: publicMcpBaseUrl
        }
      ]

      // IMPORTANT: For streamable responses, avoid platform buffering features.
      // App Service generally supports streaming, but your app code must flush chunks.
    }
  }
}

// --------------------------
// FUTURE: App Service VNET integration (commented out)
// resource vnetConn 'Microsoft.Web/sites/virtualNetworkConnections@2023-12-01' = {
//   name: '${site.name}/vnet'
//   properties: {
//     subnetResourceId: vnetIntegrationSubnetId
//     swiftSupported: true
//   }
// }

// --------------------------
// FUTURE: App Service Private Endpoint + Private DNS (commented out)
// resource pe 'Microsoft.Network/privateEndpoints@2023-11-01' = {
//   name: '${prefix}-app-pe'
//   location: location
//   properties: {
//     subnet: {
//       id: <privateEndpointSubnetId>
//     }
//     privateLinkServiceConnections: [
//       {
//         name: 'appsvc-conn'
//         properties: {
//           privateLinkServiceId: site.id
//           groupIds: [ 'sites' ]
//         }
//       }
//     ]
//   }
// }
// (Optional) privateDnsZone + zoneGroup would go here too.

output defaultHostName string = site.properties.defaultHostName
output webAppName string = site.name
output principalId string = site.identity.principalId
