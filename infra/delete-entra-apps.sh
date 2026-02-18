#!/usr/bin/env bash
set -euo pipefail

########################################
# CONFIG (must match create script)
########################################
PREFIX="${PREFIX:-mcp}"
API_APP_NAME="${PREFIX}-mcp-api"
CLIENT_APP_NAME="${PREFIX}-mcp-client"

########################################
# PRECHECK
########################################
if ! az account show >/dev/null 2>&1; then
  echo "❌ Not logged into Azure. Run 'az login' first."
  exit 1
fi

TENANT_ID="$(az account show --query tenantId -o tsv)"
echo "✅ Tenant: $TENANT_ID"

########################################
# DELETE APP REGISTRATION BY NAME
########################################
delete_app_by_name () {
  local APP_NAME="$1"

  APP_ID="$(az ad app list \
    --display-name "$APP_NAME" \
    --query '[0].appId' -o tsv || true)"

  if [[ -z "${APP_ID:-}" ]]; then
    echo "ℹ️  App not found: $APP_NAME (nothing to delete)"
    return 0
  fi

  echo "🗑️  Deleting app registration: $APP_NAME ($APP_ID)"
  az ad app delete --id "$APP_ID"
}

########################################
# EXECUTION
########################################
delete_app_by_name "$CLIENT_APP_NAME"
delete_app_by_name "$API_APP_NAME"

########################################
# DONE
########################################
cat <<EOF

✅ Cleanup complete

Deleted (if existed):
- $CLIENT_APP_NAME
- $API_APP_NAME

Notes:
- Service principals are deleted automatically
- Script is safe to re-run

EOF