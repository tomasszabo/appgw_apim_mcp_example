# Application Gateway, API Management and MCP Server Example

## Overview

Example of an MCP (Model Context Protocol) weather server with OAuth 2.0 authentication, deployed on Azure with API Management, Application Gateway, and optional HTTPS support.

**Architecture:**
- **.NET 10.0 MCP Server** (App Service) - Provides weather data via MCP protocol
- **Azure API Management StandardV2** - JWT validation, API gateway, OAuth discovery endpoints
- **Application Gateway WAF v2** - Front-end with optional HTTPS and custom domain
- **Azure Key Vault** - SSL certificate storage (created when HTTPS is configured)
- **Microsoft Entra ID** - OAuth 2.0 authentication
- **Application Insights** - Monitoring and logging

**Designed for integration with:**
- Microsoft Copilot Studio
- Other OAuth 2.0 clients supporting RFC 8414 (Authorization Server Metadata) and RFC 9728 (Protected Resource Metadata)

## Prerequisites

1. **Azure Subscription** with permissions to:
   - Create resource groups
   - Deploy Bicep templates
   - Create Microsoft Entra ID app registrations
   - Create Key Vault and import certificates (for HTTPS)

2. **Azure CLI** installed and authenticated:
   ```bash
   az login
   az account set --subscription <subscription-id>
   ```

3. **Required tools:**
   - `jq` - JSON parsing in deployment scripts
   - `bash` or `zsh` - Script execution

4. **For HTTPS deployment (required for Copilot Studio and OAuth2 authentication):**
   - Valid SSL certificate in `.pfx` format (not self-signed)
   - Certificate password
   - Custom domain name with ability to configure DNS

## Deployment

Deploy with HTTPS and custom domain:

```bash
cd infra

# Configure HTTPS settings
export LOCATION="swedencentral"
export PREFIX="mcp"
export RG_NAME="apim-mcp-rg"

# Certificate configuration
export CERT_FILE="/path/to/certificate.pfx"
export CERT_PASSWORD="your-pfx-password"
export CERT_NAME="my-domain-cert"

# Domain configuration
export CUSTOM_DOMAIN_NAME="api.example.com"

# Deploy
./deploy.sh
```

**Deployment process (3 steps):**
1. ✅ **Resource Group** - Created if it doesn't exist
2. 🔑 **Key Vault** - Created and certificate imported
3. 🚀 **Infrastructure** - Deploys with HTTPS listener on App Gateway

**Time:** ~20-25 minutes

### Post-Deployment: Configure DNS (HTTPS only)

After successful deployment with HTTPS:

1. Note the **App Gateway Public IP** from deployment output
2. Create DNS A record:
   ```
   Name:  api.example.com (or your subdomain)
   Type:  A
   Value: <App-Gateway-Public-IP>
   TTL:   300 (or your preference)
   ```
3. Wait for DNS propagation (5-10 minutes)
4. Test HTTPS endpoint:
   ```bash
   curl https://api.example.com/weather-mcp/health
   ```

## Environment Variables Reference (deployment script)

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `LOCATION` | No | `swedencentral` | Azure region for deployment |
| `PREFIX` | No | `mcp` | Prefix for all resource names |
| `RG_NAME` | No | `apim-mcp-rg` | Resource group name |
| `CERT_FILE` | HTTPS only | - | Path to `.pfx` certificate file |
| `CERT_PASSWORD` | HTTPS only | - | Password for `.pfx` file |
| `CERT_NAME` | HTTPS only | - | Certificate name in Key Vault |
| `CUSTOM_DOMAIN_NAME` | HTTPS only | - | Custom domain (e.g., `api.example.com`) |

**Auto-configured by deploy script:**
- `TENANT_ID` - Microsoft Entra tenant ID
- `MCP_API_AUDIENCE` - API application ID URI
- `MCP_CLIENT_APP_ID` - Client application ID

## Deployment Output

After successful deployment, you'll see:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🎉 MCP Server Deployment Complete
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📍 Public Endpoints (via App Gateway):
   🌐 MCP Base URL:      http://x.x.x.x/weather-mcp
   🔒 MCP Base URL HTTPS: https://api.example.com/weather-mcp
   🌍 App Gateway IP:    x.x.x.x

🔐 OAuth Configuration:
   Tenant ID:         xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   Client App ID:     xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   API Audience:      api://xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   Required Role:     MCP.ReadWrite   Required Scope:    mcp.access

📦 Resources:
   Resource Group:    apim-mcp-rg
   App Service:       mcp-app-xxxxx
   Key Vault:         mcp-kv-xxxxx
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Testing the Deployment

### Health Check
```bash
# HTTP
curl http://<app-gateway-ip>/weather-mcp/health

# HTTPS (after DNS configured)
curl https://api.example.com/weather-mcp/health
```

### OpenID Connect Discovery Endpoint

**OpenID Connect Metadata:**
```bash
curl http://<app-gateway-ip>/weather-mcp/.well-known/openid-configuration
```

### MCP Protocol Test

Test with authenticated token:
```bash
# Get token (replace with your values)
TOKEN=$(az account get-access-token \
  --resource api://your-api-audience \
  --query accessToken -o tsv)

# Call MCP endpoint
curl -X POST https://api.example.com/weather-mcp/stream \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

## Copilot Studio Integration

### Configure OAuth 2.0 Authentication

Microsoft Copilot Studio requires **manual OAuth configuration** (dynamic discovery is not supported with Entra ID). Follow these steps:

#### Step 1: Get Configuration Values

After deployment, note these values from the output:
- **Tenant ID**: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`
- **Client App ID**: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` (MCP_CLIENT_APP_ID)
- **API Audience**: `api://xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/mcp.access`
- **MCP Base URL**: `https://api.example.com/weather-mcp` (use HTTPS URL)

#### Step 2: Configure Connection in Copilot Studio

1. Open your copilot in **Copilot Studio**
2. Go to **Your Agent** → **Tools** → **Add tool** → **Model Context Protocol**
3. Select **OAuth 2.0** as authentication type 

#### Step 3: Manual OAuth Configuration

Since Copilot Studio doesn't support dynamic discovery with Entra ID, configure manually:

**Connection Settings:**
- **MCP Server URL**: `https://api.example.com/weather-mcp`
  - ⚠️ Must match exactly (no trailing slash)
  - Use HTTPS URL from deployment output

**OAuth 2.0 Configuration:**
- **Grant Type**: `Authorization Code`
- **Authorization URL**: 
  ```
  https://login.microsoftonline.com/{TENANT_ID}/oauth2/v2.0/authorize
  ```
  Replace `{TENANT_ID}` with your actual tenant ID

- **Token URL**: 
  ```
  https://login.microsoftonline.com/{TENANT_ID}/oauth2/v2.0/token
  ```
  Replace `{TENANT_ID}` with your actual tenant ID

- **Client ID**: Use the **Client App ID** from deployment output

- **Client Secret**: 
  1. Go to Azure Portal → Entra ID → App Registrations
  2. Find your client app (name starts with your PREFIX)
  3. Go to **Certificates & secrets** → **New client secret**
  4. Copy the secret value (keep it secure!)

- **Scope**: 
  ```
  api://{API_AUDIENCE}/mcp.access
  ```
  Replace `{API_AUDIENCE}` with the app ID from API Audience (without `api://` prefix)
  
  Example: If API Audience is `api://e0c4645c-d305-4cb4-8864-1d11b7fddfa2`, use:
  ```
  api://e0c4645c-d305-4cb4-8864-1d11b7fddfa2/mcp.access
  ```

- **Redirect URI**: Copy the redirect URI provided by Copilot Studio and:
  1. Go to Azure Portal → Entra ID → App Registrations
  2. Find your client app
  3. Go to **Authentication** → **Add a platform** → **Web**
  4. Add the Copilot Studio redirect URI
  5. Save

#### Step 4: Test the Connection

1. Click **Test connection** in Copilot Studio
2. You'll be redirected to sign in with your Microsoft account
3. Grant consent when prompted
4. Connection should succeed and show "Connected"

### MCP Server Configuration

After authentication is configured:

1. **MCP Endpoint URL:** Use `publicMcpBaseUrl` from deployment (HTTPS preferred)
2. The server supports these MCP tools:
   - `get_weather` - Get current weather for a city
   - `get_forecast` - Get weather forecast
3. Test queries:
   - "What's the weather in Seattle?"
   - "Get me the forecast for Paris"

⚠️ **Important Notes:**
- Always use HTTPS URLs in production
- Keep client secret secure and rotate regularly (e.g. implement [Entra Client Secret Rotation](https://github.com/aulong-msft/EntraClientSecretRotation))
- Use the exact URL from `publicMcpBaseUrl` deployment output
- For service-to-service scenarios, the `.default` scope uses app role assignment (`MCP.ReadWrite`)

## Architecture Details

### Request Flow

1. **Client** → **App Gateway** (HTTPS with custom domain or HTTP with public IP)
2. **App Gateway** → **API Management** (HTTP, internal)
3. **API Management** → Validates JWT token, checks role
4. **API Management** → **App Service** (HTTPS, internal)
5. **App Service** → Processes MCP request, returns response

### Security Features

- **JWT Validation** at API Management layer
- **Role-based access control** via:
  - App role `MCP.ReadWrite` for service-to-service (application permissions)
  - Delegated scope `mcp.access` for user context (delegated permissions)
- **WAF v2** protection via Application Gateway
- **User Assigned Managed Identity** for App Gateway → Key Vault access
- **Certificate auto-renewal** support (App Gateway uses Key Vault reference)
- **Soft delete & purge protection** on Key Vault

## Additional Documentation

- [OAuth 2.0 Setup Guide](OAUTH2_SETUP.md) - Detailed OAuth configuration
- [HTTPS Setup Guide](HTTPS_SETUP.md) - Certificate management and custom domain setup

## License
This project is licensed under the MIT License. 
