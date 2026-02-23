# OAuth2 Authorization Setup Guide

This MCP server includes OAuth2/OpenID Connect authorization support via Azure AD.

## Quick Start

### 1. Enable Authorization

Set `EnableAuth` to `true` in your configuration:

```json
{
  "AzureAd": {
    "EnableAuth": true,
    "TenantId": "{your-tenant-id}",
    "ClientId": "{your-api-app-id}",
    "Audience": "api://{your-api-app-id}",
    "RequiredRole": "MCP.ReadWrite",
    "RequiredScope": "mcp.access"
  }
}
```

### 2. Azure AD App Registration

#### Create API App Registration

1. Go to [Azure Portal](https://portal.azure.com) → Azure AD → App registrations
2. Click **New registration**
3. Enter name: `MCP Weather API`
4. Register
5. Go to **App roles**
   - Click **Create app role**
   - Display name: `MCP Read Write Access`
   - Allowed member types: `Applications` (for service-to-service auth)
   - Value: `MCP.ReadWrite`
   - Create
6. Go to **Expose an API**
   - Click **Add a scope**
   - Scope name: `mcp.access`
   - Who can consent: `Admins and users`
   - Admin consent display name: `Access MCP Server`
   - Admin consent description: `Allow the application to access MCP server on behalf of the signed-in user`
   - Save
7. Copy the `Application (client) ID` → use as `ClientId` and `Audience`

#### Create Client App Registration (Service Principal)

1. Create another app registration: `MCP Weather Client`
2. Go to **Certificates & secrets**
3. Click **New client secret** → copy the value (save it securely!)
4. Go to **API Permissions**
5. Click **Add a permission** → **APIs my organization uses**
6. Search for your API app (MCP Weather API)
7. Select **Application permissions** → `MCP.ReadWrite` (app role)
8. Click **Grant admin consent** to auto-approve

#### Token Acquisition (Service Principal)

Use Client Credentials flow to get a token with the `MCP.ReadWrite` role:

```bash
TENANT_ID="your-tenant-id"
CLIENT_ID="client-app-id"
CLIENT_SECRET="client-secret-value"
API_AUDIENCE="api://api-app-id"

TOKEN=$(curl -s -X POST \
  "https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=$CLIENT_ID" \
  -d "client_secret=$CLIENT_SECRET" \
  -d "scope=$API_AUDIENCE/.default" \
  -d "grant_type=client_credentials" | jq -r .access_token)

echo "https://jwt.ms?token=$TOKEN"
```

The token should have a `roles` claim containing `"MCP.ReadWrite"`.

#### Configure for Copilot Studio Integration

**CRITICAL**: For Copilot Studio to obtain tokens, you must:

1. **Use Your Actual Tenant ID** (not "common"):
   - Go to Azure Portal → Microsoft Entra ID → Overview
   - Copy **Tenant ID** (e.g., `12345678-1234-1234-1234-123456789abc`)
   - Update `appsettings.json` with this value

2. **Pre-authorize Copilot Studio** (option 1 - recommended):
   - In your MCP API app registration → **Expose an API**
   - Under **Authorized client applications**, click **Add a client application**
   - Add Copilot Studio's client ID (get from Microsoft/Copilot Studio docs)
   - Select the `mcp.access` scope

3. **Configure Admin Consent** (option 2 - if pre-auth not available):
   - Users will see consent screen on first use
   - Tenant admin can pre-consent for all users via API Permissions

4. **Verify OAuth Metadata**:
   ```bash
   # Test the discovery endpoint
   curl http://YOUR_APIM_URL/weather-mcp/.well-known/oauth-protected-resource
   
   # Should return:
   # {
   #   "resource": "http://YOUR_APIM_URL/weather-mcp",
   #   "authorization_servers": ["https://login.microsoftonline.com/{TENANT_ID}/v2.0"]
   # }
   ```

**Common Token Acquisition Failures**:
- `AADSTS700016`: Copilot Studio client not registered or found
- `AADSTS65001`: User/admin hasn't consented to `mcp.access` scope
- `AADSTS50105`: User not assigned to the API application (if user assignment required)
- `AADSTS700016`: Application {API_APP_ID} not found in tenant

### 3. Configuration Values

```json
{
  "AzureAd": {
    "Instance": "https://login.microsoftonline.com/",
    "TenantId": "12345678-1234-1234-1234-123456789abc",  // MUST be your actual tenant ID (NOT "common")
    "ClientId": "abcdef01-2345-6789-abcd-ef0123456789",  // From API app registration
    "Audience": "api://abcdef01-2345-6789-abcd-ef0123456789", // Must match Application ID URI
    "RequiredRole": "MCP.ReadWrite",    // The app role name from App roles
    "RequiredScope": "mcp.access",      // The delegated scope from Expose an API
    "Authority": "https://login.microsoftonline.com/12345678-1234-1234-1234-123456789abc/v2.0",
    "EnableAuth": true
  }
}
```

⚠️ **IMPORTANT**: 
- Replace `"common"` with your **actual tenant ID** from Entra ID Overview
- The authorization endpoints in OAuth metadata will use this tenant ID
- Copilot Studio cannot obtain tokens from multi-tenant "common" endpoint for custom APIs

## Authorization Flow

### For Direct API Calls (Dev/Testing)

1. **Get a token** from Azure AD:

```bash
curl -X POST \
  -H "Content-Type: application/x-www-form-urlencoded" \
  https://login.microsoftonline.com/{tenant-id}/oauth2/v2.0/token \
  --data-urlencode "client_id={client-app-id}" \
  --data-urlencode "client_secret={client-secret}" \
  --data-urlencode "scope=api://{api-app-id}/.default" \
  --data-urlencode "grant_type=client_credentials"
```

2. **Call the MCP endpoint** with the token:

```bash
curl -X POST http://localhost:5000/ \
  -H "Authorization: Bearer {access-token}" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":"1","method":"tools/list"}'
```

### For APIM

The APIM gateway automatically validates JWT tokens in the policy:
- Validates the token signature using Azure AD's public keys
- Checks the `aud` (audience) claim
- Verifies the required `roles` claim contains the app role
- Returns 403 if validation fails

## Authorization Check in Code

The `AuthorizationService` provides methods to check authorization:

```csharp
public class MyTool
{
    private readonly AuthorizationService _authService;
    
    public MyTool(AuthorizationService authService)
    {
        _authService = authService;
    }
    
    public async Task<string> ProtectedMethod()
    {
        // This throws UnauthorizedAccessException if not authorized
        _authService.RequireAuthorization();
        
        // ... your code here
    }
}
```

## Authorization Strategies

### Strategy 1: Disabled (Default - Development)
```json
"EnableAuth": false
```
- No token validation
- Any request is allowed
- Suitable for local development

### Strategy 2: Enabled at API Level (Production)
```json
"EnableAuth": true
```
- APIM validates JWT tokens
- MCP tools check authorization via `RequireAuthorization()`
- Recommended for production

### Strategy 3: Custom Claims
```csharp
var principal = _authService.GetPrincipal();
var tenantId = _authService.GetClaimValue("tid");
var Copilot Studio Cannot Obtain Tokens

**Symptom**: Copilot Studio shows "Authentication failed" or "Cannot connect to MCP server"

**Root Causes**:
1. **TenantId is "common"**: 
   - ❌ `"TenantId": "common"`
   - ✅ Use your actual tenant ID
   
2. **Copilot Studio not authorized**:
   - Go to API app → Expose an API → Authorized client applications
   - Add Copilot Studio's client ID

3. **Wrong audience in token**:
   - Token `aud` claim must match `Audience` in appsettings.json
   - Check token at [jwt.ms](https://jwt.ms)

4. **Network/firewall blocking token endpoint**:
   - Copilot Studio needs access to `login.microsoftonline.com`

**Debug Steps**:
```bash
# 1. Verify OAuth metadata endpoints
curl http://YOUR_APIM_URL/weather-mcp/.well-known/oauth-authorization-server | jq .

# 2. Check if authorization_endpoint uses correct tenant ID (NOT "common")
# Should see: "authorization_endpoint": "https://login.microsoftonline.com/{ACTUAL_TENANT_ID}/oauth2/v2.0/authorize"

# 3. Manually test token acquisition with same flow Copilot Studio uses
# (requires Copilot Studio's client ID and redirect URI)
```

### Token Validation Fails at MCP Server

1. Check `TenantId` matches token issuer
2. Verify `Audience` matches Application ID URI in app registration
3. Ensure token includes required `roles` claim (`MCP.ReadWrite`) or `scp` claim (`mcp.access`)
4. Confirm token was issued by correct tenant (check `iss` and `tid` claims)

### Missing Role or Scope Error

1. Confirm role `MCP.ReadWrite` is defined in API app registration → App roles
2. Confirm scope `mcp.access` is defined in API app registration → Expose an API
3. Verify client app service principal has been granted the `MCP.ReadWrite` app role (for service-to-service)
4. Check token claims:
   - `roles` claim should contain `MCP.ReadWrite` (for application permissions)
   - `scp` claim should contain `mcp.access` (for delegated permissions)
5. Use Client Credentials flow for service-to-service (gets `roles` claim)
6. Use Authorization Code flow for user context (gets `scp` claim)

### 401 Unauthorized

1. Verify JWT token is valid (check at [jwt.ms](https://jwt.ms))
2. Ensure token was issued by your tenant (not common)
3. Verify Bearer token is in Authorization header
4. Check APIM policy is forwarding Authorization header to backend
5. Confirm token audience matches MCP server's expected audience
### 401 Unauthorized

1. Verify JWT token is valid (check at [jwt.ms](https://jwt.ms))
2. Ensure token was issued by your tenant
3. Verify Bearer token is in Authorization header

## Disabling Authorization When Needed

To temporarily disable authorization for testing:

```json
{
  "AzureAd": {
    "EnableAuth": false
  }
}
```

All tools will be accessible without authentication.

## Security Best Practices

1. ✅ Always use HTTPS in production
2. ✅ Use strong client secrets
3. ✅ Rotate credentials regularly
4. ✅ Use certificate-based authentication when possible
5. ✅ Validate tokens at both APIM and application levels
6. ✅ Log authorization failures for audit trails

## Additional Resources

- [Azure AD OAuth2 Flow](https://docs.microsoft.com/en-us/azure/active-directory/azuread-dev/v1-oauth2-implicit-grant-flow)
- [Microsoft Identity Platform](https://docs.microsoft.com/en-us/azure/active-directory/develop/)
- [APIM JWT Validation](https://docs.microsoft.com/en-us/azure/api-management/api-management-access-restriction-policies#jwt-validation)
