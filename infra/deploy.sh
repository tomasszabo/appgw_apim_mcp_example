#!/usr/bin/env bash
set -euo pipefail

########################################
# CONFIG
########################################
LOCATION="${LOCATION:-swedencentral}"
PREFIX="${PREFIX:-mcp}"
RG_NAME="${RG_NAME:-apim-mcp-rg}"

# Key Vault & Certificate Configuration (optional)
CERT_FILE="${CERT_FILE:-}"  # Path to .pfx certificate file
CERT_PASSWORD="${CERT_PASSWORD:-}"  # Password protecting the .pfx file
CERT_NAME="${CERT_NAME:-}"  # Name to store certificate in Key Vault (e.g., my-domain-cert)

# HTTPS Configuration (optional)
CUSTOM_DOMAIN_NAME="${CUSTOM_DOMAIN_NAME:-}"  # Domain name (e.g., api.example.com) - leave empty for HTTP only

########################################
# CREATE ENTRA APPS
########################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/create-entra-apps.sh"

########################################
# VALIDATE ENV VARS
########################################
REQUIRED_VARS=(
  TENANT_ID
  MCP_API_AUDIENCE
  MCP_CLIENT_APP_ID
)

for VAR in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!VAR:-}" ]]; then
    echo "❌ Missing environment variable: $VAR"
    exit 1
  fi
done

########################################
# CREATE RG IF NEEDED
########################################
if ! az group show --name "$RG_NAME" >/dev/null 2>&1; then
  echo "➡️  Creating resource group $RG_NAME"
  az group create \
    --name "$RG_NAME" \
    --location "$LOCATION" >/dev/null
else
  echo "✅ Resource group exists"
fi

########################################
# STEP 1: DEPLOY KEY VAULT (ONLY IF CERTIFICATE PROVIDED)
########################################

KEY_VAULT_NAME=""
KEY_VAULT_ID=""

if [[ -n "$CERT_FILE" ]]; then
  echo ""
  echo "🔑 Step 1: Deploying Key Vault (certificate provided)..."
  
  KEY_VAULT_OUTPUT=$(az deployment group create \
    --resource-group "$RG_NAME" \
    --template-file modules/keyvault.bicep \
    --parameters \
      location="$LOCATION" \
      prefix="$PREFIX" \
    --query "properties.outputs" \
    -o json)

  KEY_VAULT_NAME=$(echo "$KEY_VAULT_OUTPUT" | jq -r '.keyVaultName.value // empty')
  KEY_VAULT_ID=$(echo "$KEY_VAULT_OUTPUT" | jq -r '.keyVaultId.value // empty')

  if [[ -z "$KEY_VAULT_NAME" ]]; then
    echo "❌ Key Vault deployment failed"
    exit 1
  fi

  echo "✅ Key Vault created: $KEY_VAULT_NAME"
  
  # Grant current user permissions to import certificates
  echo "   Granting certificate import permissions to current user..."
  CURRENT_USER_ID=$(az ad signed-in-user show --query id -o tsv)
  
  az keyvault set-policy \
    --name "$KEY_VAULT_NAME" \
    --object-id "$CURRENT_USER_ID" \
    --certificate-permissions import get list delete \
    --secret-permissions get list \
    --query "id" \
    -o tsv > /dev/null
  
  echo "   ✅ Permissions granted"
else
  echo ""
  echo "ℹ️  Step 1: Skipped Key Vault deployment (no certificate provided)"
fi

########################################
# STEP 2: IMPORT CERTIFICATE (IF PROVIDED)
########################################

if [[ -n "$CERT_FILE" && -n "$CERT_NAME" ]]; then
  echo ""
  echo "🔒 Step 2: Importing certificate to Key Vault..."
  
  # Validate certificate file exists
  if [[ ! -f "$CERT_FILE" ]]; then
    echo "❌ Certificate file not found: $CERT_FILE"
    exit 1
  fi
  
  # Validate certificate password is provided
  if [[ -z "$CERT_PASSWORD" ]]; then
    echo "❌ CERT_PASSWORD required for certificate import"
    exit 1
  fi
  
  # Import certificate
  echo "   Vault: $KEY_VAULT_NAME"
  echo "   File:  $CERT_FILE"
  echo "   Name:  $CERT_NAME"
  
  if CERT_ID=$(az keyvault certificate import \
    --vault-name "$KEY_VAULT_NAME" \
    --name "$CERT_NAME" \
    --file "$CERT_FILE" \
    --password "$CERT_PASSWORD" \
    --query "id" \
    -o tsv 2>&1); then
    echo "✅ Certificate imported: $CERT_NAME"
    echo "   ID: $CERT_ID"
  else
    echo "❌ Failed to import certificate"
    echo "   Error: $CERT_ID"
    exit 1
  fi
elif [[ -n "$CERT_FILE" ]]; then
  echo ""
  echo "⚠️  Step 2: Certificate file provided but CERT_NAME missing"
  echo "    Set CERT_NAME environment variable and redeploy"
  exit 1
else
  echo ""
  echo "ℹ️  Step 2: Skipped (no certificate provided, deploying HTTP only)"
fi

########################################
# STEP 3: DEPLOY MAIN INFRASTRUCTURE
########################################
echo ""
echo "🚀 Step 3: Deploying main infrastructure..."

# Build parameters array (Key Vault already deployed separately or not needed)
PARAMS=(
  "location=$LOCATION"
  "prefix=$PREFIX"
  "tenantId=$TENANT_ID"
  "mcpApiAudience=$MCP_API_AUDIENCE"
  "mcpClientAppId=$MCP_CLIENT_APP_ID"
)

# Pass existing Key Vault ID if it was created
if [[ -n "$KEY_VAULT_ID" ]]; then
  PARAMS+=("existingKeyVaultId=$KEY_VAULT_ID")
fi

# Add HTTPS parameters if both cert and domain are configured
if [[ -n "$CERT_NAME" && -n "$CUSTOM_DOMAIN_NAME" ]]; then
  echo "ℹ️  HTTPS will be configured: $CUSTOM_DOMAIN_NAME"
  PARAMS+=(
    "customDomainName=$CUSTOM_DOMAIN_NAME"
    "certificateName=$CERT_NAME"
  )
else
  echo "ℹ️  Deploying with HTTP (no HTTPS)"
fi

DEPLOYMENT_OUTPUT=$(az deployment group create \
  --resource-group "$RG_NAME" \
  --name "${PREFIX}-deployment-$(date +%Y%m%d-%H%M%S)" \
  --template-file "$SCRIPT_DIR/main.bicep" \
  --parameters "${PARAMS[@]}" \
  --query "properties.outputs" \
  -o json)

echo "✅ Infrastructure deployment complete"

########################################
# EXTRACT OUTPUTS
########################################
APP_SERVICE_NAME=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.appServiceName.value // empty')
RESOURCE_GROUP=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.resourceGroupName.value // empty')
PUBLIC_MCP_BASE_URL=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.publicMcpBaseUrl.value // empty')
PUBLIC_MCP_BASE_URL_HTTPS=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.publicMcpBaseUrlHttps.value // empty')
APP_GATEWAY_IP=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.appGatewayPublicIp.value // empty')
MCP_API_PATH=$(echo "$DEPLOYMENT_OUTPUT" | jq -r '.mcpApiPath.value // empty')

########################################
# DEPLOYMENT SUMMARY
########################################
echo ""
echo ""
cat <<EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🎉 MCP Server Deployment Complete
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📍 Public Endpoints (via App Gateway):
   🌐 MCP Base URL:      $PUBLIC_MCP_BASE_URL
EOF

if [[ -n "$PUBLIC_MCP_BASE_URL_HTTPS" && "$PUBLIC_MCP_BASE_URL_HTTPS" != "HTTPS not configured" ]]; then
  cat <<EOF
   🔒 MCP Base URL HTTPS: $PUBLIC_MCP_BASE_URL_HTTPS
EOF
fi

cat <<EOF
   🌍 App Gateway IP:    $APP_GATEWAY_IP

🔐 OAuth Configuration:
   Tenant ID:         $TENANT_ID
   Client App ID:     $MCP_CLIENT_APP_ID
   API Audience:      $MCP_API_AUDIENCE
   Required Scope:    mcp.access

📦 Resources:
   Resource Group:    $RG_NAME
   App Service:       $APP_SERVICE_NAME
EOF

if [[ -n "$KEY_VAULT_NAME" ]]; then
  cat <<EOF
   Key Vault:         $KEY_VAULT_NAME
EOF
fi

cat <<EOF
EOF

if [[ -n "$CUSTOM_DOMAIN_NAME" && -n "$CERT_NAME" ]]; then
  cat <<EOF

🔒 HTTPS Configuration:
   ✅ Enabled
   Domain:           $CUSTOM_DOMAIN_NAME
   Certificate:      $CERT_NAME

   ⚠️  TODO: Configure DNS A record
       Add DNS A record:
         Domain:  $CUSTOM_DOMAIN_NAME
         Value:   $APP_GATEWAY_IP
       
       Wait 5-10 minutes for DNS propagation
       Then test: curl https://$CUSTOM_DOMAIN_NAME/$MCP_API_PATH/health
EOF
else
  cat <<EOF

🔒 HTTPS Configuration:
   ❌ Not configured (using HTTP only)
   
   To enable HTTPS on next deployment:
   export CERT_FILE='path/to/certificate.pfx'
   export CERT_PASSWORD='pfx-password'
   export CERT_NAME='my-domain-cert'
   export CUSTOM_DOMAIN_NAME='api.example.com'
   ./deploy.sh
EOF
fi

cat <<EOF

⚠️  IMPORTANT: Use PUBLIC_MCP_BASE_URL when configuring Copilot Studio
    This ensures exact URL matching for OAuth protected resource metadata.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
