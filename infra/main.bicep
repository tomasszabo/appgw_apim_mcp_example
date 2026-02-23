targetScope = 'resourceGroup'

@description('Deployment location')
param location string = 'swedencentral'

@description('Name prefix for all resources')
param prefix string = 'mcp'

@description('APIM publisher email')
param publisherEmail string = 'someone@example.com'

@description('APIM publisher name')
param publisherName string = 'Someone'

@description('OAuth2 audience, e.g. api://<api-app-id>')
param mcpApiAudience string

@description('OAuth2 client app ID from Entra')
param mcpClientAppId string

@description('Microsoft Entra tenant ID')
param tenantId string

@description('Required OAuth2 app role for authorization (leave empty to skip role check)')
param mcpRequiredRole string = 'MCP.ReadWrite'

@description('Required OAuth2 scope for authorization (leave empty to skip scope check)')
param mcpRequiredScope string = 'mcp.access'

@description('Key Vault ID from separate deployment (deploy.sh Step 1). Format: /subscriptions/{subId}/resourceGroups/{rg}/providers/Microsoft.KeyVault/vaults/{name}. Leave empty for HTTP-only deployment.')
param existingKeyVaultId string = ''

@description('Custom domain name for HTTPS (e.g., api.example.com). Leave empty to use HTTP only.')
param customDomainName string = ''

@description('Name of certificate in Key Vault (e.g., my-domain-cert). Used only if customDomainName is provided.')
param certificateName string = ''

// MCP API path used in APIM and for constructing public URL
var mcpApiPath = 'weather-mcp'

// NOTE: Resource group is created by deploy.sh BEFORE this deployment
// Key Vault is also created separately by deploy.sh (Step 1) when certificate is provided
// This ensures the SSL certificate exists before App Gateway deployment
// The Key Vault ID is passed via the existingKeyVaultId parameter

// --------------------------
// Monitoring (Application Insights + Log Analytics - shared across all resources)
// --------------------------
module monitoring './modules/monitoring.bicep' = {
  name: '${prefix}-monitoring'
  params: {
    location: location
    prefix: prefix
  }
}

// --------------------------
// Network (VNET for AppGW; other subnets are present but commented for future PE/VNET integ)
// --------------------------
module net './modules/network.bicep' = {
  name: '${prefix}-net'
  params: {
    location: location
    prefix: prefix
  }
}

// --------------------------
// App Service (MCP Server backend) - public for now
// Depends on networking to get the public IP address for OAuth metadata
// --------------------------
module app './modules/appservice.bicep' = {
  name: '${prefix}-app'
  params: {
    location: location
    prefix: prefix
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    tenantId: tenantId
    clientAppId: mcpClientAppId
    apiAudience: mcpApiAudience
    requiredRole: mcpRequiredRole
    requiredScope: mcpRequiredScope
    // Use HTTPS with custom domain if configured, otherwise HTTP with public IP
    publicMcpBaseUrl: !empty(customDomainName) ? 'https://${customDomainName}/${mcpApiPath}' : 'http://${net.outputs.pipAddress}/${mcpApiPath}'
    // For future VNET integration uncomment and pass subnet id:
    // vnetIntegrationSubnetId: net.outputs.appServiceIntegrationSubnetId
  }
}

// --------------------------
// API Management (Standard v2, public, no VNET integration)
// Proxies /mcp to App Service + validates Entra JWT
// --------------------------
module apim './modules/apim.bicep' = {
  name: '${prefix}-apim'
  params: {
    location: location
    prefix: prefix
    publisherEmail: publisherEmail
    publisherName: publisherName

    // Backend MCP endpoint on App Service (base URL only; operations define their paths)
    mcpBackendBaseUrl: 'https://${app.outputs.defaultHostName}'

    // Entra / OAuth2 validation inputs
    tenantId: tenantId
    mcpApiAudience: mcpApiAudience
    requiredRole: mcpRequiredRole
    requiredScope: mcpRequiredScope
    
    // Shared Application Insights
    appInsightsId: monitoring.outputs.appInsightsId
    appInsightsInstrumentationKey: monitoring.outputs.appInsightsInstrumentationKey
  }
}

// --------------------------
// App Gateway (WAF v2) in front of APIM (public APIM backend)
// HTTPS requires:
// 1. A valid certificate (not self-signed) uploaded to Key Vault via deploy.sh
// 2. The certificate must be in .pfx format
// 3. Key Vault is created by this module
//
// To upload certificate to Key Vault after deployment:
//   az keyvault certificate import \
//     --vault-name <keyvault-name> \
//     --name <cert-name> \
//     --file <certificate.pfx> \
//     --password <pfx-password>
//
// Then redeploy with: customDomainName and certificateName parameters
// --------------------------
module appgw './modules/appgw.bicep' = {
  name: '${prefix}-appgw'
  params: {
    location: location
    prefix: prefix
    appGwSubnetId: net.outputs.appGwSubnetId
    pipId: net.outputs.pipId

    // APIM public gateway hostname
    apimGatewayHostname: apim.outputs.apimGatewayHostname

    // HTTPS certificate configuration (optional)
    // Key Vault ID is provided from deploy.sh when certificate was imported
    keyVaultId: existingKeyVaultId
    customDomainName: customDomainName
    certificateName: certificateName
  }
}

output appGatewayPublicIp string = net.outputs.pipAddress
output apimGatewayHostname string = apim.outputs.apimGatewayHostname
output publicMcpBaseUrl string = !empty(customDomainName) ? 'https://${customDomainName}/${mcpApiPath}' : 'http://${net.outputs.pipAddress}/${mcpApiPath}'
output publicMcpBaseUrlHttp string = 'http://${net.outputs.pipAddress}/${mcpApiPath}'
output publicMcpBaseUrlHttps string = !empty(customDomainName) ? 'https://${customDomainName}/${mcpApiPath}' : 'HTTPS not configured'
output mcpApiPath string = mcpApiPath
output mcpApiBaseUrl string = apim.outputs.mcpApiBaseUrl
output mcpEndpointUrl string = apim.outputs.mcpEndpointUrl
output healthCheckUrl string = apim.outputs.healthCheckUrl
output oidcDiscoveryUrl string = apim.outputs.oidcDiscoveryUrl
output appServiceUrl string = 'https://${app.outputs.defaultHostName}'
output appServiceName string = app.outputs.webAppName
output keyVaultId string = existingKeyVaultId
output keyVaultName string = !empty(existingKeyVaultId) ? split(existingKeyVaultId, '/')[8] : ''
output resourceGroupName string = resourceGroup().name
output appInsightsInstrumentationKey string = monitoring.outputs.appInsightsInstrumentationKey
output appInsightsConnectionString string = monitoring.outputs.appInsightsConnectionString
