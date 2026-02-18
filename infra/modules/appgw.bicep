param location string
param prefix string
param appGwSubnetId string
param pipId string

@description('APIM gateway hostname, e.g. <apim>.azure-api.net')
param apimGatewayHostname string

@description('Key Vault resource ID for storing SSL certificate (e.g., /subscriptions/.../resourceGroups/.../providers/Microsoft.KeyVault/vaults/my-keyvault)')
param keyVaultId string

@description('Custom domain name for HTTPS (e.g., api.example.com). Set to empty string to skip HTTPS setup.')
param customDomainName string = ''

@description('Name of the certificate in Key Vault (e.g., my-domain-cert). The certificate must already exist in Key Vault.')
param certificateName string = ''

var wafPolicyName = '${prefix}-wafpol-${uniqueString(resourceGroup().id)}'
var agwName = '${prefix}-agw-${uniqueString(resourceGroup().id)}'
var hasHttps = !empty(customDomainName) && !empty(certificateName)
// Extract Key Vault name from resource ID and construct HTTPS URI for App Gateway
// Input: /subscriptions/.../resourceGroups/.../providers/Microsoft.KeyVault/vaults/{name}
// Output: https://{name}.vault.azure.net/secrets/{cert}
// Note: Do NOT use /latest - App Gateway auto-resolves to latest version
var keyVaultName = !empty(keyVaultId) ? split(keyVaultId, '/')[8] : ''
var keyVaultSecretUri = !empty(keyVaultId) ? 'https://${keyVaultName}.vault.azure.net/secrets/${certificateName}' : ''

resource pip 'Microsoft.Network/publicIPAddresses@2023-11-01' existing = {
  name: split(pipId, '/')[8]
}

// User Assigned Managed Identity for App Gateway to access Key Vault
resource appGwIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (hasHttps) {
  name: '${prefix}-agw-identity-${uniqueString(resourceGroup().id)}'
  location: location
}

// Grant the identity access to Key Vault secrets (for HTTPS certificate)
resource keyVaultAccessPolicy 'Microsoft.KeyVault/vaults/accessPolicies@2023-07-01' = if (hasHttps && !empty(keyVaultId)) {
  name: '${split(keyVaultId, '/')[8]}/add'
  properties: {
    accessPolicies: [
      {
        tenantId: subscription().tenantId
        objectId: appGwIdentity.properties.principalId
        permissions: {
          secrets: [
            'get'
            'list'
          ]
        }
      }
    ]
  }
}

resource wafPolicy 'Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies@2023-11-01' = {
  name: wafPolicyName
  location: location
  properties: {
    policySettings: {
      mode: 'Detection'
    }
    managedRules: {
      managedRuleSets: [
        {
          ruleSetType: 'OWASP'
          ruleSetVersion: '3.2'
        }
      ]
    }
  }
}

resource agw 'Microsoft.Network/applicationGateways@2024-10-01' = {
  name: agwName
  location: location
  identity: hasHttps ? {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${appGwIdentity.id}': {}
    }
  } : null
  properties: {
    sku: {
      name: 'WAF_v2'
      tier: 'WAF_v2'
      capacity: 1
    }
    firewallPolicy: {
      id: wafPolicy.id
    }
    gatewayIPConfigurations: [
      {
        name: 'gwipcfg'
        properties: {
          subnet: {
            id: appGwSubnetId
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'feip'
        properties: {
          publicIPAddress: {
            id: pip.id
          }
        }
      }
    ]
    frontendPorts: concat(
      [
        {
          name: 'feport80'
          properties: {
            port: 80
          }
        }
      ],
      hasHttps ? [
        {
          name: 'feport443'
          properties: {
            port: 443
          }
        }
      ] : []
    )
    backendAddressPools: [
      {
        name: 'be-apim'
        properties: {
          backendAddresses: [
            {
              fqdn: apimGatewayHostname
            }
          ]
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'bhs-https'
        properties: {
          port: 443
          protocol: 'Https'
          pickHostNameFromBackendAddress: true
          requestTimeout: 60
          probe: {
            id: resourceId('Microsoft.Network/applicationGateways/probes', agwName, 'probe-apim')
          }
        }
      }
    ]
    probes: [
      {
        name: 'probe-apim'
        properties: {
          protocol: 'Https'
          path: '/status-0123456789abcdef'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: true
          match: {
            statusCodes: [
              '200-399'
            ]
          }
        }
      }
    ]
    httpListeners: concat(
      [
        {
          name: 'listener80'
          properties: {
            frontendIPConfiguration: {
              id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', agwName, 'feip')
            }
            frontendPort: {
              id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', agwName, 'feport80')
            }
            protocol: 'Http'
          }
        }
      ],
      hasHttps ? [
        {
          name: 'listener443'
          properties: {
            frontendIPConfiguration: {
              id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', agwName, 'feip')
            }
            frontendPort: {
              id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', agwName, 'feport443')
            }
            protocol: 'Https'
            sslCertificate: {
              id: resourceId('Microsoft.Network/applicationGateways/sslCertificates', agwName, 'ssl-cert')
            }
            hostNames: [
              customDomainName
            ]
          }
        }
      ] : []
    )
    requestRoutingRules: concat(
      hasHttps ? [
        {
          name: 'rule-redirect-http'
          properties: {
            ruleType: 'Basic'
            httpListener: {
              id: resourceId('Microsoft.Network/applicationGateways/httpListeners', agwName, 'listener80')
            }
            redirectConfiguration: {
              id: resourceId('Microsoft.Network/applicationGateways/redirectConfigurations', agwName, 'redirect-http-https')
            }
            priority: 100
          }
        }
      ] : [
        {
          name: 'rule80'
          properties: {
            ruleType: 'Basic'
            httpListener: {
              id: resourceId('Microsoft.Network/applicationGateways/httpListeners', agwName, 'listener80')
            }
            backendAddressPool: {
              id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', agwName, 'be-apim')
            }
            backendHttpSettings: {
              id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', agwName, 'bhs-https')
            }
            priority: 100
          }
        }
      ],
      hasHttps ? [
        {
          name: 'rule443'
          properties: {
            ruleType: 'Basic'
            httpListener: {
              id: resourceId('Microsoft.Network/applicationGateways/httpListeners', agwName, 'listener443')
            }
            backendAddressPool: {
              id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', agwName, 'be-apim')
            }
            backendHttpSettings: {
              id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', agwName, 'bhs-https')
            }
            priority: 110
          }
        }
      ] : []
    )
    redirectConfigurations: hasHttps ? [
      {
        name: 'redirect-http-https'
        properties: {
          redirectType: 'Permanent'
          targetListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', agwName, 'listener443')
          }
          includePath: true
          includeQueryString: true
        }
      }
    ] : []
    sslCertificates: hasHttps ? [
      {
        name: 'ssl-cert'
        properties: {
          keyVaultSecretId: keyVaultSecretUri
        }
      }
    ] : []
  }
}

output appGatewayName string = agw.name
