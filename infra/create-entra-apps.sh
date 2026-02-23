#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-apim}"
API_APP_NAME="${PREFIX}-mcp-api"
CLIENT_APP_NAME="${PREFIX}-mcp-client"

########################################
# Pre-check
########################################
az account show >/dev/null
TENANT_ID="$(az account show --query tenantId -o tsv)"
export TENANT_ID

########################################
# Create / get API app (NO identifierUri yet)
########################################
API_APP_ID="$(az ad app list --display-name "$API_APP_NAME" --query '[0].appId' -o tsv || true)"

if [[ -z "$API_APP_ID" ]]; then
  echo "➡️  Creating API app"
  API_APP_ID="$(az ad app create \
    --display-name "$API_APP_NAME" \
    --sign-in-audience AzureADMyOrg \
    --query appId -o tsv)"
else
  echo "✅ API app exists"
fi

########################################
# Set Identifier URI safely: api://<appId>
########################################
echo "➡️  Setting Identifier URI to api://$API_APP_ID"
az ad app update \
  --id "$API_APP_ID" \
  --identifier-uris "api://$API_APP_ID"

export MCP_API_APP_ID="$API_APP_ID"
export MCP_API_AUDIENCE="api://$API_APP_ID"

########################################
# Create / get Client app
########################################
CLIENT_APP_ID="$(az ad app list --display-name "$CLIENT_APP_NAME" --query '[0].appId' -o tsv || true)"

if [[ -z "$CLIENT_APP_ID" ]]; then
  echo "➡️  Creating client app"
  CLIENT_APP_ID="$(az ad app create \
    --display-name "$CLIENT_APP_NAME" \
    --sign-in-audience AzureADMyOrg \
    --query appId -o tsv)"
else
  echo "✅ Client app exists"
fi

export MCP_CLIENT_APP_ID="$CLIENT_APP_ID"

########################################
# Create OAuth2 delegated scope: mcp.access
########################################
SCOPE_VALUE="mcp.access"

echo "➡️  Configuring OAuth2 delegated scope '$SCOPE_VALUE'"

# Read the full api configuration
EXISTING_API_JSON="$(az ad app show --id "$API_APP_ID" --query "api" -o json 2>/dev/null || echo 'null')"

# Set requestedAccessTokenVersion if not already set
if [[ "$EXISTING_API_JSON" == "null" || "$(echo "$EXISTING_API_JSON" | jq -r '.requestedAccessTokenVersion')" == "null" ]]; then
  echo "➡️  Setting requestedAccessTokenVersion to 2"
  OBJECT_ID="$(az ad app show --id "$API_APP_ID" --query "id" -o tsv)"
  az rest --method PATCH \
    --uri "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID" \
    --body '{"api":{"requestedAccessTokenVersion":2}}' >/dev/null
  
  # Re-read API config
  EXISTING_API_JSON="$(az ad app show --id "$API_APP_ID" --query "api" -o json)"
fi

# Extract existing scopes
if [[ "$EXISTING_API_JSON" == "null" || "$EXISTING_API_JSON" == "{}" ]]; then
  EXISTING_SCOPES_JSON='[]'
else
  EXISTING_SCOPES_JSON="$(echo "$EXISTING_API_JSON" | jq -c '.oauth2PermissionScopes // []')"
fi

# Check if scope already exists
SCOPE_ID="$(echo "$EXISTING_SCOPES_JSON" | jq -r --arg v "$SCOPE_VALUE" '.[] | select(.value==$v) | .id' | head -n1)"

if [[ -z "${SCOPE_ID:-}" || "$SCOPE_ID" == "null" ]]; then
  echo "➡️  Creating delegated scope '$SCOPE_VALUE'"
  NEW_SCOPE_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"

  # Build updated scopes array
  UPDATED_SCOPES="$(echo "$EXISTING_SCOPES_JSON" | jq -c --arg id "$NEW_SCOPE_ID" \
    --arg v "$SCOPE_VALUE" \
    '. + [{
      "id": $id,
      "value": $v,
      "adminConsentDescription": "Allow the application to access MCP server on behalf of the signed-in user",
      "adminConsentDisplayName": "Access MCP Server",
      "userConsentDescription": "Allow the application to access MCP server on your behalf",
      "userConsentDisplayName": "Access MCP Server",
      "isEnabled": true,
      "type": "User"
    }]')"

  # Update via Graph API
  OBJECT_ID="$(az ad app show --id "$API_APP_ID" --query "id" -o tsv)"
  TEMP_FILE=$(mktemp)
  jq -n --argjson scopes "$UPDATED_SCOPES" '{api:{oauth2PermissionScopes:$scopes}}' > "$TEMP_FILE"
  
  az rest --method PATCH \
    --uri "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID" \
    --body @"$TEMP_FILE" >/dev/null

  rm -f "$TEMP_FILE"

  echo "✅ Delegated scope created: $SCOPE_VALUE ($NEW_SCOPE_ID)"
  SCOPE_ID="$NEW_SCOPE_ID"
else
  echo "✅ Delegated scope already exists: $SCOPE_VALUE ($SCOPE_ID)"
fi

########################################
# Create app role: MCP.ReadWrite
########################################
# App role value (what shows in 'roles' claim)
ROLE_VALUE="MCP.ReadWrite"

# Ensure identifier URI is policy-compliant
az ad app update --id "$API_APP_ID" --identifier-uris "api://$API_APP_ID" >/dev/null

# Read existing app roles
EXISTING_ROLES_JSON="$(az ad app show --id "$API_APP_ID" --query "appRoles" -o json)"
if [[ "$EXISTING_ROLES_JSON" == "null" || -z "$EXISTING_ROLES_JSON" ]]; then
  EXISTING_ROLES_JSON='[]'
fi

# If role doesn't exist, append it
ROLE_ID="$(echo "$EXISTING_ROLES_JSON" | jq -r --arg v "$ROLE_VALUE" '.[] | select(.value==$v) | .id' | head -n1)"
if [[ -z "${ROLE_ID:-}" || "$ROLE_ID" == "null" ]]; then
  echo "➡️  Creating app role '$ROLE_VALUE'"
  NEW_ROLE_ID="$(uuidgen)"

  UPDATED_ROLES_JSON="$(echo "$EXISTING_ROLES_JSON" | jq -c \
    --arg id "$NEW_ROLE_ID" \
    --arg v "$ROLE_VALUE" \
    '. + [{
      "id": $id,
      "value": $v,
      "displayName": "MCP Read Write Access",
      "description": "Allows read and write access to MCP server",
      "isEnabled": true,
      "allowedMemberTypes": ["Application"]
    }]' )"

  az ad app update --id "$API_APP_ID" --set appRoles="$UPDATED_ROLES_JSON" >/dev/null

  echo "done"
  ROLE_ID="$NEW_ROLE_ID"
else
  echo "✅ App role already exists: $ROLE_VALUE ($ROLE_ID)"
fi

########################################
# Create service principals and assign role
########################################
echo "➡️  Creating service principal for API app"
API_SP_ID="$(az ad sp list --filter "appId eq '$API_APP_ID'" --query '[0].id' -o tsv || true)"

if [[ -z "$API_SP_ID" ]]; then
  API_SP_ID="$(az ad sp create --id "$API_APP_ID" --query id -o tsv)"
  echo "✅ API service principal created: $API_SP_ID"
else
  echo "✅ API service principal already exists: $API_SP_ID"
fi

echo "➡️  Creating service principal for client app"
CLIENT_SP_ID="$(az ad sp list --filter "appId eq '$CLIENT_APP_ID'" --query '[0].id' -o tsv || true)"

if [[ -z "$CLIENT_SP_ID" ]]; then
  CLIENT_SP_ID="$(az ad sp create --id "$CLIENT_APP_ID" --query id -o tsv)"
  echo "✅ Client service principal created: $CLIENT_SP_ID"
else
  echo "✅ Client service principal already exists: $CLIENT_SP_ID"
fi

# Assign the app role to the client service principal
echo "➡️  Assigning app role '$ROLE_VALUE' to client app"
az rest \
  --method POST \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$API_SP_ID/appRoleAssignedTo" \
  --body @- <<EOJSON 2>/dev/null || echo "✅ App role assignment already exists"
{
  "principalId": "$CLIENT_SP_ID",
  "appRoleId": "$ROLE_ID",
  "resourceId": "$API_SP_ID"
}
EOJSON

echo "✅ App role configured"

########################################
# Grant delegated scope to client app
########################################
echo "➡️  Adding delegated scope to client app's required resource access"

# Microsoft Graph User.Read scope ID (well-known constant)
MS_GRAPH_USER_READ_SCOPE_ID="e1fe6dd8-ba31-4d61-89e7-88639da4683d"

# Build the requiredResourceAccess structure with BOTH:
# 1. MCP API scopes and roles
# 2. Microsoft Graph User.Read (required for OAuth flows)

REQUIRED_RESOURCE_ACCESS='[
  {
    "resourceAppId": "'$API_APP_ID'",
    "resourceAccess": [
      {
        "id": "'$SCOPE_ID'",
        "type": "Scope"
      },
      {
        "id": "'$ROLE_ID'",
        "type": "Role"
      }
    ]
  },
  {
    "resourceAppId": "00000003-0000-0000-c000-000000000000",
    "resourceAccess": [
      {
        "id": "'$MS_GRAPH_USER_READ_SCOPE_ID'",
        "type": "Scope"
      }
    ]
  }
]'

az ad app update --id "$CLIENT_APP_ID" --set requiredResourceAccess="$REQUIRED_RESOURCE_ACCESS" >/dev/null

echo "✅ Delegated scope and app role added to client app's required resource access"
echo "✅ Microsoft Graph User.Read scope added to client app"

# Add client app to API app's knownClientApplications so the scope is visible in API permissions
echo "➡️  Adding client app to API app's knownClientApplications"
OBJECT_ID="$(az ad app show --id "$API_APP_ID" --query "id" -o tsv)"

az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID" \
  --body '{"api":{"knownClientApplications":["'$CLIENT_APP_ID'"]}}' >/dev/null

echo "✅ Client app added to API app's knownClientApplications"

# Grant admin consent to the delegated scope
echo "➡️  Granting admin consent for mcp.access scope"
API_SP_ID="$(az ad sp show --id "$API_APP_ID" --query id -o tsv)"
CLIENT_SP_ID="$(az ad sp show --id "$CLIENT_APP_ID" --query id -o tsv)"

az rest --method POST \
  --uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" \
  --body '{"clientId":"'$CLIENT_SP_ID'","consentType":"AllPrincipals","resourceId":"'$API_SP_ID'","scope":"mcp.access"}' \
  >/dev/null 2>&1 || echo "ℹ️  Scope grant may already exist"

echo "✅ Admin consent granted for mcp.access scope"

# Grant admin consent to Microsoft Graph User.Read
echo "➡️  Granting admin consent for Microsoft Graph User.Read"
MS_GRAPH_SP_ID="$(az ad sp show --id 00000003-0000-0000-c000-000000000000 --query id -o tsv)"

az rest --method POST \
  --uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" \
  --body '{"clientId":"'$CLIENT_SP_ID'","consentType":"AllPrincipals","resourceId":"'$MS_GRAPH_SP_ID'","scope":"User.Read"}' \
  >/dev/null 2>&1 || echo "ℹ️  User.Read grant may already exist"

echo "✅ Admin consent granted for Microsoft Graph User.Read"

########################################
# Configure redirect URI and enable implicit grant flow
########################################
REDIRECT_URI="https://jwt.ms"
echo "➡️  Configuring client app for jwt.ms (redirect URI + implicit grant)"

# Get existing web config and merge with implicit grant settings
EXISTING_WEB_CONFIG="$(az ad app show --id "$CLIENT_APP_ID" --query "web" -o json)"
if [[ "$EXISTING_WEB_CONFIG" == "null" || -z "$EXISTING_WEB_CONFIG" ]]; then
  EXISTING_WEB_CONFIG='{}'
fi

# Build web object with redirect URIs and implicit grant settings
WEB_CONFIG_JSON="$(echo "$EXISTING_WEB_CONFIG" | jq -c --arg uri "$REDIRECT_URI" '{
  "redirectUris": ((.redirectUris // []) + (if (.redirectUris // []) | contains([$uri]) then [] else [$uri] end)),
  "implicitGrantSettings": {
    "enableAccessTokenIssuance": true,
    "enableIdTokenIssuance": true
  }
}')"

az ad app update --id "$CLIENT_APP_ID" --set web="$WEB_CONFIG_JSON" >/dev/null

echo "✅ Client app configured (redirect URI + implicit grant)"

########################################
# Output
########################################
AUTH_URL="https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/authorize?client_id=$CLIENT_APP_ID&response_type=token&redirect_uri=https://jwt.ms&response_mode=fragment&scope=$MCP_API_AUDIENCE/.default&state=12345&nonce=678910"

# Create/update .env file with all outputs for deployment
ENV_FILE=".entra.env"
cat > "$ENV_FILE" <<EOF
TENANT_ID=$TENANT_ID
MCP_API_APP_ID=$MCP_API_APP_ID
MCP_API_AUDIENCE=$MCP_API_AUDIENCE
MCP_CLIENT_APP_ID=$MCP_CLIENT_APP_ID
MCP_REQUIRED_SCOPE=$SCOPE_VALUE
MCP_REQUIRED_ROLE=$ROLE_VALUE
EOF

echo "✅ Entra configuration saved to $ENV_FILE"

cat <<EOF

✅ Entra setup complete (Identifier URI policy compliant)

TENANT_ID=$TENANT_ID
MCP_API_APP_ID=$MCP_API_APP_ID
MCP_API_AUDIENCE=$MCP_API_AUDIENCE
MCP_CLIENT_APP_ID=$MCP_CLIENT_APP_ID
DELEGATED_SCOPE=$SCOPE_VALUE
APP_ROLE=$ROLE_VALUE

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔐 Authorization URL (open in browser):
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

$AUTH_URL

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
After authorization, you'll be redirected to jwt.ms
where you can inspect the token.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

EOF