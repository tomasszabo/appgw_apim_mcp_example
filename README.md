# MCP Weather Server - Azure Deployment

## Overview

Enterprise-grade MCP (Model Context Protocol) weather server with OAuth 2.0 authentication, deployed on Azure with API Management, Application Gateway, and optional HTTPS support.

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

4. **For HTTPS deployment (optional):**
   - Valid SSL certificate in `.pfx` format (not self-signed)
   - Certificate password
   - Custom domain name with ability to configure DNS

## Deployment

### Option 1: HTTP Only (Quick Start)

Deploy without HTTPS for testing or development:

```bash
cd infra

# Optional: Configure deployment settings
export LOCATION="swedencentral"         # Azure region
export PREFIX="mcp"                      # Resource name prefix
export RG_NAME="apim-mcp-rg"            # Resource group name

# Deploy
./deploy.sh
```

**Deployment process (3 steps):**
1. ✅ **Resource Group** - Created if it doesn't exist
2. ⏭️ **Key Vault** - Skipped (no certificate)
3. 🚀 **Infrastructure** - Deploys App Service, APIM, App Gateway (HTTP), monitoring

**Time:** ~15-20 minutes

### Option 2: HTTPS with Custom Domain

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

## Environment Variables Reference

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
   API Audience:      api://xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   Required Scope:    mcp.access

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

### OAuth Discovery Endpoints

**Authorization Server Metadata (RFC 8414):**
```bash
curl http://<app-gateway-ip>/weather-mcp/.well-known/oauth-authorization-server
```

**Protected Resource Metadata (RFC 9728):**
```bash
curl http://<app-gateway-ip>/weather-mcp/.well-known/oauth-protected-resource
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

Use the deployment output to configure Copilot Studio:

1. **MCP Endpoint URL:** Use `publicMcpBaseUrl` (HTTPS preferred)
2. **Authentication:** OAuth 2.0
3. **Client ID:** Use `mcpClientAppId` from output
4. **Scope:** `{apiAudience}/mcp.access`
5. **Authorization URL:** Auto-discovered via RFC 8414
6. **Token URL:** Auto-discovered via RFC 8414

⚠️ **Important:** Use the exact URL from `publicMcpBaseUrl` output for OAuth protected resource metadata to work correctly.

## Architecture Details

### Request Flow

1. **Client** → **App Gateway** (HTTPS with custom domain or HTTP with public IP)
2. **App Gateway** → **API Management** (HTTP, internal)
3. **API Management** → Validates JWT token, checks scope
4. **API Management** → **App Service** (HTTPS, internal)
5. **App Service** → Processes MCP request, returns response

### Security Features

- **JWT Validation** at API Management layer
- **OAuth 2.0 scope enforcement** (`mcp.access`)
- **WAF v2** protection via Application Gateway
- **User Assigned Managed Identity** for App Gateway → Key Vault access
- **Certificate auto-renewal** support (App Gateway uses Key Vault reference)
- **Soft delete & purge protection** on Key Vault

## Troubleshooting

### Certificate Import Failed
```
ERROR: Unable to load certificate file: Permission denied
```
**Fix:** Ensure certificate file is readable:
```bash
chmod 600 /path/to/certificate.pfx
```

### DNS Not Resolving
**Wait 5-10 minutes** for DNS propagation, then verify:
```bash
nslookup api.example.com
dig api.example.com
```

### APIM Deployment Slow
API Management StandardV2 deployment takes 10-15 minutes. This is normal.

### Key Vault Access Denied
Ensure you have permissions to import certificates:
```bash
az keyvault set-policy \
  --name <keyvault-name> \
  --upn <your-email> \
  --certificate-permissions import get list
```

## Clean Up

To delete all deployed resources:

```bash
az group delete --name apim-mcp-rg --yes --no-wait
```

**Note:** Also delete Entra ID app registrations if desired:
```bash
cd infra
./delete-entra-apps.sh
```

## Additional Documentation

- [OAuth 2.0 Setup Guide](OAUTH2_SETUP.md) - Detailed OAuth configuration
- [HTTPS Setup Guide](HTTPS_SETUP.md) - Certificate management and custom domain setup

## Deploy Script Behavior

The deployment script is **idempotent** and performs:

1. **Entra ID App Registration:**
   - Creates or reuses API app (resource application) with Application ID URI
   - Creates or reuses client app for delegation
   - Assigns OAuth2 delegated scope (`mcp.access`)
   - Grants admin consent automatically

2. **Azure Resource Deployment:**
   - Creates resource group (if needed)
   - Deploys Key Vault + imports certificate (if HTTPS configured)
   - Deploys main infrastructure (App Service, APIM, App Gateway, monitoring)

3. **Configuration:**
   - Configures App Service with OAuth settings
   - Sets up APIM JWT validation policy
   - Creates App Gateway HTTPS listener (if certificate provided)
   - Establishes monitoring with Application Insights



## License
This project is licensed under the MIT License. 