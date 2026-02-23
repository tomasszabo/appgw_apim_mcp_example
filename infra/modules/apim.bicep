param location string
param prefix string
param publisherEmail string
param publisherName string

@description('Base URL for MCP backend, e.g. https://<app>.azurewebsites.net')
param mcpBackendBaseUrl string

param tenantId string
@description('Audience for JWT validation (Identifier URI), e.g. api://<prefix>-mcp-api')
param mcpApiAudience string
@description('Expected role value for authorization, e.g. MCP.ReadWrite (leave empty to skip role check)')
param requiredRole string = ''
@description('Expected scope value for authorization, e.g. mcp.access (leave empty to skip scope check)')
param requiredScope string = ''

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

// Operation policy for MCP endpoint - rate limit tool calls by session
resource opMcpPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2023-05-01-preview' = {
  name: 'policy'
  parent: opMcp
  properties: {
    format: 'xml'
    value: '''
<policies>
  <inbound>
    <!-- Rate limit tool calls by Mcp-Session-Id header -->
    <set-variable name="body" value="@(context.Request.Body.As<string>(preserveContent: true))" />
    <choose>
        <when condition="@(
            Newtonsoft.Json.Linq.JObject.Parse((string)context.Variables["body"])["method"] != null 
            && Newtonsoft.Json.Linq.JObject.Parse((string)context.Variables["body"])["method"].ToString() == "tools/call"
        )">
        <rate-limit-by-key 
            calls="1" 
            renewal-period="60" 
            counter-key="@(
                context.Request.Headers.GetValueOrDefault("Mcp-Session-Id", "unknown")
            )" />
        </when>
    </choose>
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

resource opOidcDiscovery 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = {
  name: 'oidc-discovery'
  parent: mcpApi
  properties: {
    displayName: 'OpenID Connect Discovery'
    description: 'OpenID Connect Discovery endpoint - redirects to Azure AD'
    method: 'GET'
    urlTemplate: '/.well-known/openid-configuration'
    request: {
      queryParameters: []
      headers: []
      representations: []
    }
    responses: [
      {
        statusCode: 302
        description: 'Redirect to Azure AD OIDC configuration'
        representations: [
          {
            contentType: 'application/json'
          }
        ]
      }
    ]
  }
}

// Operation policy for OIDC discovery - no auth required
resource opOidcDiscoveryPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2023-05-01-preview' = {
  name: 'policy'
  parent: opOidcDiscovery
  properties: {
    format: 'xml'
    value: '''
<policies>
  <inbound>
    <!-- CORS policy for OIDC discovery endpoint -->
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

// REST API Operations for Weather Data

resource opWeatherGet 'Microsoft.ApiManagement/service/apis/operations@2023-05-01-preview' = {
  name: 'get-weather'
  parent: mcpApi
  properties: {
    displayName: 'Get Weather by Location'
    description: 'Get current weather data for a specified location'
    method: 'GET'
    urlTemplate: '/api/weather/{location}'
    templateParameters: [
      {
        name: 'location'
        description: 'Location name (e.g., Seattle, Paris)'
        type: 'string'
        required: true
        values: []
      }
    ]
    request: {
      queryParameters: []
      headers: []
      representations: []
    }
    responses: [
      {
        statusCode: 200
        description: 'Weather data for location'
        representations: [
          {
            contentType: 'application/json'
          }
        ]
      }
      {
        statusCode: 400
        description: 'Bad request - invalid location'
        representations: [
          {
            contentType: 'application/json'
          }
        ]
      }
    ]
  }
}

resource opWeatherGetPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2023-05-01-preview' = {
  name: 'policy'
  parent: opWeatherGet
  properties: {
    format: 'xml'
    value: '''
<policies>
  <inbound>
    <base />
    <!-- CORS for REST API -->
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
    
    <!-- Rate limiting: 1000 requests per minute -->
    <rate-limit calls="1000" renewal-period="60" />
    
    <!-- Validate JWT access token issued by Entra ID -->
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
        <audience>00000002-0000-0000-c000-000000000000</audience> <!-- Microsoft Graph audience used by Copilot Studio -->
      </audiences>

      <issuers>
        <issuer>${replace(environment().authentication.loginEndpoint, 'login.microsoftonline.com/', 'sts.windows.net/')}${tenantId}/</issuer>
        <issuer>${environment().authentication.loginEndpoint}${tenantId}/v2.0</issuer>
      </issuers>

    </validate-jwt>
    
    <!-- Extract token claims for validation -->
    <set-variable name="tokenAudience" value="@(context.Request.Headers.GetValueOrDefault(&quot;Authorization&quot;,&quot;&quot;).AsJwt()?.Claims.GetValueOrDefault(&quot;aud&quot;, &quot;&quot;))" />
    <set-variable name="tokenScopes" value="@(context.Request.Headers.GetValueOrDefault(&quot;Authorization&quot;,&quot;&quot;).AsJwt()?.Claims.GetValueOrDefault(&quot;scp&quot;, &quot;&quot;))" />
    <set-variable name="tokenRoles" value="@(context.Request.Headers.GetValueOrDefault(&quot;Authorization&quot;,&quot;&quot;).AsJwt()?.Claims.GetValueOrDefault(&quot;roles&quot;, &quot;&quot;))" />
    <set-variable name="isGraphAudience" value="@((string)context.Variables[&quot;tokenAudience&quot;] == &quot;00000002-0000-0000-c000-000000000000&quot;)" />
    
    <!-- Validate that token has required scope or role (skip for Graph audience tokens which don't have these claims) -->
    <set-variable name="hasRequiredRole" value="@((bool)context.Variables[&quot;isGraphAudience&quot;] || string.IsNullOrEmpty(&quot;${requiredRole}&quot;) || ((string)context.Variables[&quot;tokenRoles&quot;] ?? &quot;&quot;).Split(&apos; &apos;).Contains(&quot;${requiredRole}&quot;))" />
    <set-variable name="hasRequiredScope" value="@((bool)context.Variables[&quot;isGraphAudience&quot;] || string.IsNullOrEmpty(&quot;${requiredScope}&quot;) || ((string)context.Variables[&quot;tokenScopes&quot;] ?? &quot;&quot;).Split(&apos; &apos;).Contains(&quot;${requiredScope}&quot;))" />
    
    <choose>
      <when condition="@((bool)context.Variables[&quot;hasRequiredRole&quot;] || (bool)context.Variables[&quot;hasRequiredScope&quot;])">
        <!-- Valid scope or role found, or using Graph audience (no scope/role validation), continue -->
      </when>
      <otherwise>
        <return-response>
          <set-status code="403" reason="Forbidden" />
          <set-header name="Content-Type" exists-action="override">
            <value>application/json</value>
          </set-header>
          <set-body>{&quot;error&quot;:&quot;insufficient_scope&quot;,&quot;error_description&quot;:&quot;Token missing required role (${requiredRole}) or scope (${requiredScope})&quot;}</set-body>
        </return-response>
      </otherwise>
    </choose>
    
    <!-- Set backend address based on context -->
    <set-backend-service base-url="${mcpBackendBaseUrl}" />
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
        headers: [
          'Authorization'
        ]
        body: {
          bytes: 8192
        }
      }
      response: {
        body: {
          bytes: 0
        }
      }
    }
    backend: {
      request: {
        headers: [
          'Authorization'
        ]
        body: {
          bytes: 8192
        }
      }
      response: {
        body: {
          bytes: 0
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
        headers: [
          'Authorization'
        ]
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
output oidcDiscoveryUrl string = 'https://${apim.name}.azure-api.net/${apiPath}/.well-known/openid-configuration'
