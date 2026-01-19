#!/bin/bash
# Deplo Azure Connection Setup Script
# Run in Azure Cloud Shell (https://shell.azure.com) or with Azure CLI where you are logged in.
# Creates an App Registration, Service Principal, client secret, and assigns Contributor on your subscription.

set -e

# Check for az and jq
command -v az >/dev/null 2>&1 || { echo "❌ Azure CLI (az) not found. Run this in Azure Cloud Shell: https://shell.azure.com"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "❌ jq not found. Azure Cloud Shell includes jq. Run at: https://shell.azure.com"; exit 1; }

echo "🔧 Deplo Azure connection setup"
echo ""

# Get current subscription and tenant
echo "📋 Getting subscription and tenant..."
ACCT=$(az account show 2>/dev/null) || { echo "❌ Not logged in. Run: az login"; exit 1; }
SUBSCRIPTION_ID=$(echo "$ACCT" | jq -r '.id')
TENANT_ID=$(echo "$ACCT" | jq -r '.tenantId')
SUB_NAME=$(echo "$ACCT" | jq -r '.name')
echo "   Subscription: $SUB_NAME ($SUBSCRIPTION_ID)"
echo "   Tenant: $TENANT_ID"
echo ""

# Create App Registration
APP_NAME="DeploApp-$(date +%s)"
echo "📝 Creating App Registration: $APP_NAME..."
APP_JSON=$(az ad app create --display-name "$APP_NAME" -o json 2>/dev/null) || {
  echo "❌ Failed to create App Registration. Ensure you have permission (e.g. Application Developer or Application.ReadWrite.OwnedBy)."
  exit 1
}
APP_ID=$(echo "$APP_JSON" | jq -r '.appId')
echo "   ✅ App ID (Client ID): $APP_ID"
echo ""

# Create Service Principal for the app
echo "🔗 Creating Service Principal..."
az ad sp create --id "$APP_ID" -o none 2>/dev/null || true
echo "   ⏳ Waiting for Service Principal to propagate..."
sleep 5
echo "   ✅ Service Principal ready"
echo ""

# Create client secret (resets app credentials; returns one password)
echo "🔑 Creating client secret..."
CRED_JSON=$(az ad app credential reset --id "$APP_ID" -o json 2>/dev/null) || {
  echo "❌ Failed to create client secret."
  exit 1
}
CLIENT_SECRET=$(echo "$CRED_JSON" | jq -r '.password')
if [ -z "$CLIENT_SECRET" ] || [ "$CLIENT_SECRET" = "null" ]; then
  echo "❌ Could not read client secret from 'az ad app credential reset'."
  exit 1
fi
echo "   ✅ Client secret created"
echo ""

# Assign Contributor role on the subscription
echo "📌 Assigning Contributor role on subscription..."
az role assignment create \
  --assignee "$APP_ID" \
  --role "Contributor" \
  --scope "/subscriptions/$SUBSCRIPTION_ID" \
  -o none 2>/dev/null || {
  echo "❌ Failed to assign Contributor. You need RBAC permissions (e.g. Owner or User Access Administrator) on the subscription."
  exit 1
}
echo "   ✅ Contributor role assigned"
echo ""

# Build JSON output (jq -n --arg properly escapes the secret)
OUTPUT_JSON=$(jq -n \
  --arg tenantId "$TENANT_ID" \
  --arg subscriptionId "$SUBSCRIPTION_ID" \
  --arg clientId "$APP_ID" \
  --arg clientSecret "$CLIENT_SECRET" \
  '{tenantId:$tenantId,subscriptionId:$subscriptionId,clientId:$clientId,clientSecret:$clientSecret}')

echo "✅ Setup complete!"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Copy ONE of the blocks below into the Deplo app to complete"
echo "  the Azure connection (paste in the 'Azure credentials' field)."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "JSON:"
echo "$OUTPUT_JSON"
echo ""
echo "Base64 (alternative):"
printf "%s" "$OUTPUT_JSON" | base64 -w 0 2>/dev/null || printf "%s" "$OUTPUT_JSON" | base64
echo ""
echo ""
echo "⚠️  Keep these credentials secure. Do not share or commit to version control."
