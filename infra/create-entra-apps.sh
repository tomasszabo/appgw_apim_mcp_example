#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-mcp}"
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
# Grant delegated permission: mcp.access
########################################
# New custom scope value (what shows in 'scp' claim)
SCOPE_VALUE="${SCOPE_VALUE:-mcp.access}"

# Ensure identifier URI is policy-compliant
az ad app update --id "$API_APP_ID" --identifier-uris "api://$API_APP_ID" >/dev/null

# Read existing scopes from the correct location
EXISTING_SCOPES_JSON="$(az ad app show --id "$API_APP_ID" --query "api.oauth2PermissionScopes" -o json)"
if [[ "$EXISTING_SCOPES_JSON" == "null" || -z "$EXISTING_SCOPES_JSON" ]]; then
  EXISTING_SCOPES_JSON='[]'
fi

# If scope doesn't exist, append it and update the FULL api object
SCOPE_ID="$(echo "$EXISTING_SCOPES_JSON" | jq -r --arg v "$SCOPE_VALUE" '.[] | select(.value==$v) | .id' | head -n1)"
if [[ -z "${SCOPE_ID:-}" || "$SCOPE_ID" == "null" ]]; then
  echo "➡️  Creating delegated scope '$SCOPE_VALUE'"
  NEW_SCOPE_ID="$(uuidgen)"

  UPDATED_SCOPES_JSON="$(echo "$EXISTING_SCOPES_JSON" | jq -c \
    --arg id "$NEW_SCOPE_ID" \
    --arg v "$SCOPE_VALUE" \
    '. + [{
      "id": $id,
      "value": $v,
      "type": "User",
      "isEnabled": true,
      "adminConsentDisplayName": "Access MCP Server",
      "adminConsentDescription": "Allows tools to access MCP server",
      "userConsentDisplayName": "Access MCP Server",
      "userConsentDescription": "Allows tools to access MCP server"
    }]' )"

  # Build the full api object. Updating nested api.oauth2PermissionScopes directly is flaky in az cli.
  API_OBJ_JSON="$(jq -cn --argjson scopes "$UPDATED_SCOPES_JSON" '{
    requestedAccessTokenVersion: 2,
    oauth2PermissionScopes: $scopes
  }')"

  az ad app update --id "$API_APP_ID" --set api="$API_OBJ_JSON" >/dev/null

  echo "done"
  SCOPE_ID="$NEW_SCOPE_ID"
else
  echo "✅ Scope already exists: $SCOPE_VALUE ($SCOPE_ID)"
fi

########################################
# Create service principal for API app (required for consent)
########################################
echo "➡️  Creating service principal for API app"
API_SP_ID="$(az ad sp list --filter "appId eq '$API_APP_ID'" --query '[0].id' -o tsv || true)"

if [[ -z "$API_SP_ID" ]]; then
  az ad sp create --id "$API_APP_ID"
  echo "✅ API service principal created"
else
  echo "✅ API service principal already exists: $API_SP_ID"
fi

# Grant the delegated permission to the client app
# az ad app permission add expects resourceAccess.id (scope/appRole GUID)
echo "➡️  Granting delegated permission '$SCOPE_VALUE' to client app"
az ad app permission add \
  --id "$CLIENT_APP_ID" \
  --api "$API_APP_ID" \
  --api-permissions "${SCOPE_ID}=Scope" >/dev/null

# Grant user consent for the delegated permission
echo "➡️  Granting user consent for delegated permissions"
az ad app permission grant \
  --id "$CLIENT_APP_ID" \
  --api "$API_APP_ID" \
  --scope "$SCOPE_VALUE" >/dev/null || echo "⚠️  User consent may already be granted"

echo "✅ Permissions configured"

########################################
# Create service principal for client app (required for token requests)
########################################
echo "➡️  Creating service principal for client app"
CLIENT_SP_ID="$(az ad sp list --filter "appId eq '$CLIENT_APP_ID'" --query '[0].id' -o tsv || true)"

if [[ -z "$CLIENT_SP_ID" ]]; then
  az ad sp create --id "$CLIENT_APP_ID"
  echo "✅ Service principal created"
else
  echo "✅ Service principal already exists: $CLIENT_SP_ID"
fi

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
AUTH_URL="https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/authorize?client_id=$CLIENT_APP_ID&response_type=token&redirect_uri=https://jwt.ms&response_mode=fragment&scope=$MCP_API_AUDIENCE/$SCOPE_VALUE&state=12345&nonce=678910"

cat <<EOF

✅ Entra setup complete (Identifier URI policy compliant)

TENANT_ID=$TENANT_ID
MCP_API_APP_ID=$MCP_API_APP_ID
MCP_API_AUDIENCE=$MCP_API_AUDIENCE
MCP_CLIENT_APP_ID=$MCP_CLIENT_APP_ID
DELEGATED_SCOPE=$SCOPE_VALUE

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔐 Authorization URL (open in browser):
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

$AUTH_URL

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
After authorization, you'll be redirected to jwt.ms
where you can inspect the token.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

EOF