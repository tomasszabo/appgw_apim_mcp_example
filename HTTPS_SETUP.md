# HTTPS Setup Guide for App Gateway

This guide explains how to configure HTTPS with a custom domain for your MCP server's App Gateway.

## Overview

1. **Key Vault is created automatically** during `deploy.sh` execution
2. **Certificate must be imported** before enabling HTTPS
3. **Domain and certificate name** are provided to `deploy.sh` to enable HTTPS
4. **DNS A record** is manually configured to point to App Gateway IP

## Prerequisites

- Valid SSL/TLS certificate in **.pfx** format (not self-signed - Copilot Studio will reject it)
- Custom domain name (e.g., `api.example.com`)
- Certificate must match the domain name and include the full chain (root + intermediates)
- Azure CLI installed

## Step 1: Initial Deployment (Key Vault Created Automatically)

Key Vault is created automatically during the first deployment. You don't need to create it manually.

First deployment (HTTP only):
```bash
export TENANT_ID="..."
export MCP_API_AUDIENCE="..."
export MCP_CLIENT_APP_ID="..."

cd infra
./deploy.sh
```

This deployment creates:
- ✅ Key Vault (automatically)
- ✅ App Gateway (with HTTP listener)
- ✅ All other infrastructure

Extract the Key Vault name from the deployment output (bottom of the summary).

## Step 2: Prepare Your Certificate

Ensure your certificate file (`certificate.pfx`) includes:
- Your domain's certificate
- Full certificate chain (root + intermediate certificates)
- Private key
- Protectable with a password

```bash
KEYVAULT_NAME="your-keyvault-name"
CERT_FILE="path/to/your/certificate.pfx"
CERT_NAME="my-domain-cert"  # Name in Key Vault (use hyphens, lowercase)
PFX_PASSWORD="your-pfx-password"  # Password protecting the PFX file

# Import the certificate
az keyvault certificate import \
  --vault-name "$KEYVAULT_NAME" \
  --name "$CERT_NAME" \
  --file "$CERT_FILE" \
  --password "$PFX_PASSWORD"

# Verify import
az keyvault certificate show \
  --vault-name "$KEYVAULT_NAME" \
  --name "$CERT_NAME"
```
Deploy with Certificate Import and HTTPS

Run deployment with certificate and domain parameters:

```bash
# Set certificate parameters
export CERT_FILE="path/to/certificate.pfx"           # Path to your .pfx file
export CERT_PASSWORD="your-pfx-password"             # Password protecting the .pfx
export CERT_NAME="my-domain-cert"                    # Name in Key Vault (use hyphens, lowercase)
export CUSTOM_DOMAIN_NAME="api.example.com"          # Your domain

# Set OAuth parameters (from previous deployment or Entra app creation)
export TENANT_ID="..."
export MCP_API_AUDIENCE="..."
export MCP_CLIENT_APP_ID="..."

# Run deployment
cd infra
./deploy.sh
```

This deployment will:
1. Import your certificate into Key Vault
2. Create HTTPS listener on App Gateway port 443
3. Configure HTTP → HTTPS redirect
4. Update OAuth metadata URLs to use HTTPS domain

## Step 4: Configure DNS

Point your domain to the App Gateway's public IP:

```bash
# Get the App Gateway IP (from deployment output)
APP_GATEWAY_IP="...from deployment output..."

echo "Add DNS A record:"
echo "  Domain (Name):  api.example.com"
echo "  Type:          A"
echo "  Value (TTL):   300"
echo "  Points to:     $APP_GATEWAY_IP"
```

Add this A record in your DNS provider (GoDaddy, Route53, Azure DNS, etc.)

Wait 5-10 minutes for DNS propagation.

## Step 5: Test HTTPS

```bash
# Wait for DNS to propagate
sleep 300

# Test HTTPS endpoint
curl -k "https://api.example.com/weather-mcp/health"
# Should respond: {"status":"healthy"}

# Test OAuth discovery (should show HTTPS URLs)
curl -k "https://api.example.com/weather-mcp/.well-known/oauth-authorization-server" | jq .

# The 'resource' field should match your domain
curl -k "https://api.example.comed resource should match your domain
curl -k "https://${CUSTOM_DOMAIN}/weather-mcp/.well-known/oauth-protected-resource" | jq .
```

## Troubleshooting

### Certificate Not Found in Key Vault
```bash
# List certificates in Key Vault
az keyvault certificate list --vault-name "your-keyvault-name"

# If not found, import again with correct password
```

### App Gateway Cannot Access Certificate
```bash
# Check the managed identity has access
PRINCIPAL_ID=$(az resource show --ids $APP_GATEWAY_ID --query "identity.principalId" -o tsv)
az keyvault get-policy --name "$KEYVAULT_NAME" --object-id "$PRINCIPAL_ID"

# Should show: "get", "list" under secret permissions
```

### SSL/TLS Errors

- **Certificate mismatch**: Certificate domain doesn't match CUSTOM_DOMAIN_NAME
- **Certificate expired**: Renewal needed
- **Missing chain**: Certificate doesn't include root + intermediate certs
- **Wrong format**: Certificate must be .pfx (PKCS#12), not .pem or .cer

Test certificate locally:
```bash
openssl x509 -in cert.pem -text -noout
openssl pkcs12 -info -in certificate.pfx  # Enter password when prompted
```

### DNS Not Resolving

```bash
# Verify DNS A record is added
nslookup api.example.com

# Should return App Gateway IP
# If not, wait 5-10 minutes and try again
```

### HTTPS Redirect Not Working

1. Check redirect rule is enabled in deployment output
2. Verify HTTP listener exists on port 80
3. Check WAF policy is not blocking requests

Test redirect:
```bash
curl -i -L "http://api.example.com/weather-mcp/health"
# Should show: HTTP/1.1 301 Moved Permanently
# Then: HTTP/1.1 200 OK (with HTTPS URL)
```

### App Gateway Cannot Read Certificate from Key Vault

The Bicep template automatically configures this via managed identity, so this is rare. If it occurs:

```bash
# Verify certificate exists and is importable
KEYVAULT_NAME="mcp-kv-xxxxx"  # From deployment output
az keyvault certificate show --vault-name "$KEYVAULT_NAME" --name "my-domain-cert"
```

## HTTP to HTTPS Redirect

The Bicep template automatically creates a redirect rule that:
- Redirects all HTTP requests → HTTPS
- Preserves path and query string
- Uses 301 (permanent) redirect status code

Test:
```bash
curl -i "http://${CUSTOM_DOMAIN}/weather-mcp/health"
# Should show: HTTP/1.1 301 Moved Permanently
```

## Certificate Renewal

When your certificate expires:

1. Generate/purchase new certificate
2. Store as .pfx file
3. Re-import into Key Vault with same name:
   ```bash
   az keyvault certificate import \
     --vault-name "$KEYVAULT_NAME" \
     --name "$CERT_NAME" \
     --file "new-certificate.pfx" \
     --password "$PFX_PASSWORD"
   ```
4. App Gateway automatically uses the updated certificate (via `/latest` secret reference)

## OAuth with HTTPS

Once HTTPS is configured, update your Copilot Studio OAuth configuration:

- **OAuth Discovery URL**: `https://api.example.com/weather-mcp/.well-known/oauth-authorization-server`
- **Token EndpoiAlready Imported, Now Adding Domain

If you imported a certificate in a previous deployment and want to enable HTTPS:

```bash
export CUSTOM_DOMAIN_NAME="api.example.com"
export CERT_NAME="my-domain-cert"  # Same name as previously imported
export TENANT_ID="..."
export MCP_API_AUDIENCE="..."
export MCP_CLIENT_APP_ID="..."

./deploy.sh
```

The script detects the existing certificate and redeploys App Gateway with HTTPS enabled.

### Import Certificate Without Enabling HTTPS

To import a certificate without enabling HTTPS (just setup for later):

```bash
export CERT_FILE="path/to/certificate.pfx"
export CERT_PASSWORD="your-pfx-password"
export CERT_NAME="my-domain-cert"
# Don't set CUSTOM_DOMAIN_NAME

./deploy.sh
```

Certificate is imported to Key Vault but HTTPS is not enabled. Later, run again with CUSTOM_DOMAIN_NAME set.

### Certificate Not Found in Key Vault
```bash
# List certificates in Key Vault
KEYVAULT_NAME="mcp-kv-xxxxx"  # Get from deployment output
az keyvault certificate list --vault-name "$KEYVAULT_NAME"

# If not found, re-import with deploy.shut cert.pem -days 30 -nodes \
  -subj "/C=US/ST=State/L=City/O=Org/CN=api.example.local"

# Convert to PFX
openssl pkcs12 -export -in cert.pem -inkey key.pem -out certificate.pfx \
  -name "my-cert" -passout pass:testpass123

# Import to Key Vault
az keyvault certificate import \
  --vault-name "$KEYVAULT_NAME" \
  --name "test-cert" \
  --file "certificate.pfx" \
  --password "testpass123"
```

Then deploy with:
```bash
customDomainName = "api.example.local"
certificateName = "test-cert"
```

Note: You'll need to add the domain to your `/etc/hosts` file for testing:
```
127.0.0.1 api.example.local
```

And disable certificate verification in tests:
```bash
curl -k "https://api.example.local/weather-mcp/health"  # -k = insecure (skips cert validation)
```
