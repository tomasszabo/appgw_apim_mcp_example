param location string
param prefix string
param publisherEmail string
param publisherName string

@description('Base URL for MCP backend, e.g. https://<app>.azurewebsites.net')
param mcpBackendBaseUrl string

param tenantId string
@description('Audience for JWT validation (Identifier URI), e.g. api://<prefix>-mcp-api')
param mcpApiAudience string
@description('Expected scope/role value, e.g. mcp.access')
param requiredScopeOrRole string

@description('Shared Application Insights resource ID')
param appInsightsId string
@description('Shared Application Insights instrumentation key')
param appInsightsInstrumentationKey string

var apimName = '${prefix}-apim-${uniqueString(resourceGroup().id)}'
var apiName = 'mcp'
var apiPath = 'weather-mcp'

// Extract app ID from audience (handles both api://appId and just appId formats)
var appIdFromAudience = replace(mcpApiAudience, 'api://', '')

resource apim 'Microsoft.ApiManagement/service@2023-09-01-preview' = {
  name: apimName
  location: location
  sku: {
    name: 'StandardV2'
    capacity: 1
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    publicNetworkAccess: 'Enabled'
    virtualNetworkType: 'None'
  }
}

resource mcpApi 'Microsoft.ApiManagement/service/apis@2023-05-01-preview' = {
  name: apiName
  parent: apim
  properties: {
    displayName: 'Weather MCP'
    description: 'Model Context Protocol (MCP) platform with HTTP Streamable support and integrated tools/services'
    path: apiPath
    protocols: [
      'https'
    ]
    serviceUrl: mcpBackendBaseUrl
    subscriptionRequired: false
  }
}

resource opMcp 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = {
  name: 'mcp'
  parent: mcpApi
  properties: {
    displayName: 'MCP Protocol Endpoint'
    description: 'Model Context Protocol unified endpoint handling tool discovery and execution via JSON-RPC 2.0'
    method: 'POST'
    urlTemplate: '/'
    request: {
      queryParameters: []
      headers: []
      representations: [
        {
          contentType: 'application/json'
        }
      ]
    }
    responses: [
      {
        statusCode: 200
        description: 'JSON-RPC 2.0 response'
        representations: [
          {
            contentType: 'application/json'
          }
        ]
      }
      {
        statusCode: 400
        description: 'Invalid JSON-RPC request'
        representations: [
          {
            contentType: 'application/json'
          }
        ]
      }
    ]
  }
}

resource opHealth 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = {
  name: 'health'
  parent: mcpApi
  properties: {
    displayName: 'Health Check'
    description: 'Server health status endpoint'
    method: 'GET'
    urlTemplate: '/health'
    request: {
      queryParameters: []
      headers: []
      representations: []
    }
    responses: [
      {
        statusCode: 200
        description: 'Server is healthy'
        representations: [
          {
            contentType: 'application/json'
          }
        ]
      }
    ]
  }
}

// Operation policy for health check - no auth required
resource opHealthPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2023-05-01-preview' = {
  name: 'policy'
  parent: opHealth
  properties: {
    format: 'xml'
    value: '''
<policies>
  <inbound>
    <!-- CORS policy for public health endpoint -->
    <cors allow-credentials="false">
      <allowed-origins>
        <origin>*</origin>
      </allowed-origins>
      <allowed-methods>
        <method>GET</method>
        <method>OPTIONS</method>
      </allowed-methods>
      <allowed-headers>
        <header>*</header>
      </allowed-headers>
    </cors>
    <!-- Skip API-level JWT validation for public health endpoint -->
  </inbound>
  <backend>
    <base />
  </backend>
  <outbound>
    <base />
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>
'''
  }
}

resource opOAuthDiscovery 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = {
  name: 'oauth-discovery'
  parent: mcpApi
  properties: {
    displayName: 'OAuth Discovery'
    description: 'OAuth 2.0 Authorization Server Metadata endpoint (RFC 8414)'
    method: 'GET'
    urlTemplate: '/.well-known/oauth-authorization-server'
    request: {
      queryParameters: []
      headers: []
      representations: []
    }
    responses: [
      {
        statusCode: 200
        description: 'OAuth metadata'
        representations: [
          {
            contentType: 'application/json'
          }
        ]
      }
    ]
  }
}

// Operation policy for OAuth discovery - no auth required
resource opOAuthDiscoveryPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2023-05-01-preview' = {
  name: 'policy'
  parent: opOAuthDiscovery
  properties: {
    format: 'xml'
    value: '''
<policies>
  <inbound>
    <!-- CORS policy for OAuth discovery endpoint -->
    <cors allow-credentials="false">
      <allowed-origins>
        <origin>*</origin>
      </allowed-origins>
      <allowed-methods>
        <method>GET</method>
        <method>OPTIONS</method>
      </allowed-methods>
      <allowed-headers>
        <header>*</header>
      </allowed-headers>
    </cors>
    <!-- Skip API-level JWT validation for public discovery endpoint -->
  </inbound>
  <backend>
    <base />
  </backend>
  <outbound>
    <base />
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>
'''
  }
}

resource opProtectedResource 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = {
  name: 'protected-resource'
  parent: mcpApi
  properties: {
    displayName: 'OAuth Protected Resource Metadata'
    description: 'OAuth 2.0 Protected Resource Metadata for MCP (RFC 9728) - MANDATORY for Copilot Studio'
    method: 'GET'
    urlTemplate: '/.well-known/oauth-protected-resource'
    request: {
      queryParameters: []
      headers: []
      representations: []
    }
    responses: [
      {
        statusCode: 200
        description: 'Protected resource metadata'
        representations: [
          {
            contentType: 'application/json'
          }
        ]
      }
    ]
  }
}

// Operation policy for protected resource metadata - no auth required
resource opProtectedResourcePolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2023-05-01-preview' = {
  name: 'policy'
  parent: opProtectedResource
  properties: {
    format: 'xml'
    value: '''
<policies>
  <inbound>
    <!-- CORS policy for OAuth protected resource endpoint -->
    <cors allow-credentials="false">
      <allowed-origins>
        <origin>*</origin>
      </allowed-origins>
      <allowed-methods>
        <method>GET</method>
        <method>OPTIONS</method>
      </allowed-methods>
      <allowed-headers>
        <header>*</header>
      </allowed-headers>
    </cors>
    <!-- Skip API-level JWT validation for public discovery endpoint -->
  </inbound>
  <backend>
    <base />
  </backend>
  <outbound>
    <base />
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>
'''
  }
}

// API-level policy: validate Entra JWT + ensure scope OR role
resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2023-05-01-preview' = {
  name: 'policy'
  parent: mcpApi
  properties: {
    format: 'xml'
    value: $'''
<policies>
  <inbound>
    <base />
    
    <!-- CORS policy for MCP clients -->
    <cors allow-credentials="false">
      <allowed-origins>
        <origin>*</origin>
      </allowed-origins>
      <allowed-methods>
        <method>GET</method>
        <method>POST</method>
        <method>PUT</method>
        <method>DELETE</method>
        <method>OPTIONS</method>
      </allowed-methods>
      <allowed-headers>
        <header>*</header>
      </allowed-headers>
      <expose-headers>
        <header>*</header>
      </expose-headers>
    </cors>
    
    <validate-jwt
      header-name="Authorization"
      require-scheme="Bearer"
      require-expiration-time="true"
      require-signed-tokens="true"
      failed-validation-httpcode="401"
      failed-validation-error-message="Unauthorized">

      <openid-config
        url="${environment().authentication.loginEndpoint}${tenantId}/v2.0/.well-known/openid-configuration" />

      <audiences>
        <audience>${mcpApiAudience}</audience>
        <audience>${appIdFromAudience}</audience>
      </audiences>

      <issuers>
        <issuer>${replace(environment().authentication.loginEndpoint, 'login.microsoftonline.com/', 'sts.windows.net/')}${tenantId}/</issuer>
        <issuer>${environment().authentication.loginEndpoint}${tenantId}/v2.0</issuer>
      </issuers>

    </validate-jwt>
    
    <!-- Validate that token has required scope or role -->
    <choose>
      <when condition="@{
        var token = context.Request.Headers.GetValueOrDefault(&quot;Authorization&quot;,&quot;&quot;).AsJwt();
        var scp = token?.Claims.GetValueOrDefault(&quot;scp&quot;, &quot;&quot;);
        var roles = token?.Claims.GetValueOrDefault(&quot;roles&quot;, &quot;&quot;);
        return scp.Split(&apos; &apos;).Contains(&quot;${requiredScopeOrRole}&quot;) || roles.Split(&apos; &apos;).Contains(&quot;${requiredScopeOrRole}&quot;);
      }">
        <!-- Valid scope or role found, continue -->
      </when>
      <otherwise>
        <return-response>
          <set-status code="403" reason="Forbidden" />
          <set-header name="Content-Type" exists-action="override">
            <value>application/json</value>
          </set-header>
          <set-body>@{
            return "{\&quot;error\&quot;: \&quot;insufficient_scope\&quot;, \&quot;error_description\&quot;: \&quot;The token does not have the required scope: ${requiredScopeOrRole}\&quot;}";
          }</set-body>
        </return-response>
      </otherwise>
    </choose>
    
    <!-- Set backend address based on context -->
    <set-backend-service base-url="${mcpBackendBaseUrl}" />
    
    <!-- Authorization header is automatically forwarded to backend for MCP server validation -->
  </inbound>

  <backend>
    <base />
  </backend>

  <outbound>
    <base />
  </outbound>

  <on-error>
    <base />
  </on-error>
</policies>
'''
  }
}

// ===== Application Insights & Monitoring =====

// APIM Logger for shared Application Insights
resource apimLogger 'Microsoft.ApiManagement/service/loggers@2023-05-01-preview' = {
  name: 'app-insights-logger'
  parent: apim
  properties: {
    loggerType: 'applicationInsights'
    description: 'Application Insights logger for MCP API'
    resourceId: appInsightsId
    credentials: {
      instrumentationKey: appInsightsInstrumentationKey
    }
  }
}

// APIM Diagnostic Settings for Application Insights (Service level)
resource apimDiagnostic 'Microsoft.ApiManagement/service/diagnostics@2023-05-01-preview' = {
  name: 'applicationinsights'
  parent: apim
  properties: {
    loggerId: apimLogger.id
    alwaysLog: 'allErrors'
    logClientIp: true
    httpCorrelationProtocol: 'W3C'
    verbosity: 'verbose'
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    frontend: {
      request: {
        body: {
          bytes: 8192
        }
      }
      response: {
        body: {
          bytes: 8192
        }
      }
    }
    backend: {
      request: {
        body: {
          bytes: 8192
        }
      }
      response: {
        body: {
          bytes: 8192
        }
      }
    }
  }
}

// API-level Diagnostic Settings for Application Insights
resource apiDiagnostic 'Microsoft.ApiManagement/service/apis/diagnostics@2023-05-01-preview' = {
  name: 'applicationinsights'
  parent: mcpApi
  properties: {
    loggerId: apimLogger.id
    alwaysLog: 'allErrors'
    logClientIp: true
    httpCorrelationProtocol: 'W3C'
    verbosity: 'verbose'
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    frontend: {
      request: {
        body: {
          bytes: 8192
        }
      }
      response: {
        body: {
          bytes: 8192
        }
      }
    }
    backend: {
      request: {
        body: {
          bytes: 8192
        }
      }
      response: {
        body: {
          bytes: 8192
        }
      }
    }
  }
}

output apimName string = apim.name
output apimGatewayHostname string = '${apim.name}.azure-api.net'
output mcpApiBaseUrl string = 'https://${apim.name}.azure-api.net/${apiPath}'
output mcpEndpointUrl string = 'https://${apim.name}.azure-api.net/${apiPath}/'
output healthCheckUrl string = 'https://${apim.name}.azure-api.net/${apiPath}/health'
output oauthDiscoveryUrl string = 'https://${apim.name}.azure-api.net/${apiPath}/.well-known/oauth-authorization-server'
output oauthProtectedResourceUrl string = 'https://${apim.name}.azure-api.net/${apiPath}/.well-known/oauth-protected-resource'
