#!/bin/bash
# Gateways GCP Connection Setup - Workload Identity Federation (no service account keys)
# Use this when your org blocks service account key creation (iam.disableServiceAccountKeyCreation)
# Run in Google Cloud Shell or locally with gcloud CLI

set -e

echo "🔧 Gateways GCP Setup (Workload Identity Federation) - starting..."
echo ""

# Configuration
SERVICE_ACCOUNT_ID="gateways-cloud-connection"
SERVICE_ACCOUNT_NAME="Gateways Cloud Connection Service Account"
SERVICE_ACCOUNT_DESCRIPTION="Service account for Gateways via Workload Identity Federation"
POOL_ID="gateways-pool"
PROVIDER_ID="gateways-oidc"

# Gateways OIDC issuer URL - must be HTTPS, no trailing slash. Set via env or prompt.
GCP_OIDC_ISSUER_URL="${GCP_OIDC_ISSUER_URL:-}"

# Get current project (|| true prevents set -e from exiting silently on gcloud failure)
PROJECT_ID=$(gcloud config get-value project 2>/dev/null) || true
if [ -z "$PROJECT_ID" ]; then
  echo "❌ Error: No GCP project selected. Run: gcloud config set project YOUR_PROJECT_ID"
  exit 1
fi

# Get project number (required for WIF)
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)" 2>/dev/null) || true
if [ -z "$PROJECT_NUMBER" ]; then
  echo "❌ Error: Could not get project number for $PROJECT_ID"
  exit 1
fi

echo "🔧 Gateways GCP Setup (Workload Identity Federation)"
echo "   Project: $PROJECT_ID (number: $PROJECT_NUMBER)"
echo ""

# Require OIDC issuer URL (cannot prompt when piped: curl ... | bash)
if [ -z "$GCP_OIDC_ISSUER_URL" ]; then
  echo "⚠️  GCP_OIDC_ISSUER_URL is not set."
  echo "   Set it to your Gateways API base URL (HTTPS, no trailing slash) before running."
  echo ""
  echo "   Example:"
  echo "     export GCP_OIDC_ISSUER_URL=https://api.gateways.app"
  echo "     curl -sSL https://raw.githubusercontent.com/GatewaysApp/gcp/main/gcp-setup-wif.sh | bash"
  echo ""
  if [ -t 0 ]; then
    read -p "Enter Gateways OIDC Issuer URL (e.g. https://api.gateways.app): " GCP_OIDC_ISSUER_URL
  fi
  if [ -z "$GCP_OIDC_ISSUER_URL" ]; then
    echo "❌ OIDC issuer URL is required. Run: export GCP_OIDC_ISSUER_URL=https://api.gateways.app"
    exit 1
  fi
fi

# Ensure URL has no trailing slash
GCP_OIDC_ISSUER_URL="${GCP_OIDC_ISSUER_URL%/}"
if [[ ! "$GCP_OIDC_ISSUER_URL" =~ ^https:// ]]; then
  echo "❌ OIDC issuer URL must start with https://"
  exit 1
fi

# WIF audience (required in tokens)
AUDIENCE="https://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/providers/${PROVIDER_ID}"

echo "📡 OIDC Issuer: $GCP_OIDC_ISSUER_URL"
echo "   Audience: $AUDIENCE"
echo ""

# Enable APIs
echo "🔌 Enabling APIs..."
for API in iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com cloudresourcemanager.googleapis.com compute.googleapis.com storage.googleapis.com sqladmin.googleapis.com dns.googleapis.com cloudfunctions.googleapis.com cloudbuild.googleapis.com run.googleapis.com secretmanager.googleapis.com redis.googleapis.com; do
  if gcloud services enable "$API" --project="$PROJECT_ID" 2>/dev/null; then
    echo "  ✅ $API"
  else
    echo "  ⚠️  $API (may already be enabled)"
  fi
done
echo ""

# Create or reuse service account
if gcloud iam service-accounts describe "$SERVICE_ACCOUNT_ID@$PROJECT_ID.iam.gserviceaccount.com" &>/dev/null; then
  echo "⚠️  Service account exists. Reusing..."
  SERVICE_ACCOUNT_EMAIL="$SERVICE_ACCOUNT_ID@$PROJECT_ID.iam.gserviceaccount.com"
else
  echo "📝 Creating service account..."
  SERVICE_ACCOUNT_EMAIL=$(gcloud iam service-accounts create "$SERVICE_ACCOUNT_ID" \
    --display-name="$SERVICE_ACCOUNT_NAME" \
    --description="$SERVICE_ACCOUNT_DESCRIPTION" \
    --project="$PROJECT_ID" \
    --format="value(email)")
  echo "✅ Created: $SERVICE_ACCOUNT_EMAIL"
fi
echo ""

# Grant roles to service account
echo "🔐 Granting IAM roles to service account..."
ROLES=(
  "roles/compute.admin"
  "roles/storage.admin"
  "roles/cloudsql.admin"
  "roles/iam.serviceAccountUser"
  "roles/compute.networkAdmin"
  "roles/viewer"
  "roles/dns.admin"
  "roles/cloudfunctions.admin"
  "roles/run.admin"
  "roles/secretmanager.admin"
  "roles/redis.admin"
)
for ROLE in "${ROLES[@]}"; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
    --role="$ROLE" \
    --quiet 2>/dev/null || true
done
echo "✅ Roles granted"
echo ""

# Create workload identity pool
echo "🏊 Creating Workload Identity Pool..."
if gcloud iam workload-identity-pools describe "$POOL_ID" --location=global --project="$PROJECT_ID" &>/dev/null; then
  echo "  Pool already exists"
else
  gcloud iam workload-identity-pools create "$POOL_ID" \
    --location="global" \
    --project="$PROJECT_ID" \
    --description="Gateways federation pool" \
    --display-name="Gateways Pool"
  echo "  ✅ Pool created"
fi
echo ""

# Create OIDC provider
echo "🔗 Creating OIDC provider..."
if gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
  --workload-identity-pool="$POOL_ID" \
  --location=global \
  --project="$PROJECT_ID" &>/dev/null; then
  echo "  Updating existing provider..."
  gcloud iam workload-identity-pools providers update-oidc "$PROVIDER_ID" \
    --workload-identity-pool="$POOL_ID" \
    --location=global \
    --project="$PROJECT_ID" \
    --issuer-uri="${GCP_OIDC_ISSUER_URL}/" \
    --attribute-mapping="google.subject=assertion.sub"
else
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_ID" \
    --workload-identity-pool="$POOL_ID" \
    --location=global \
    --project="$PROJECT_ID" \
    --issuer-uri="${GCP_OIDC_ISSUER_URL}/" \
    --attribute-mapping="google.subject=assertion.sub"
  echo "  ✅ Provider created"
fi
echo ""

# Grant pool principal permission to impersonate the service account
# principalSet://iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/POOL_ID/attribute.sub/CONNECTION_ID
# We use principalSet with attribute to allow any sub from our IdP - our app controls which connection_id we put in sub
POOL_PRINCIPAL="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}"
echo "🔑 Granting pool impersonation permission..."
gcloud iam service-accounts add-iam-policy-binding "$SERVICE_ACCOUNT_EMAIL" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="$POOL_PRINCIPAL" \
  --quiet 2>/dev/null || true
echo "✅ Impersonation granted"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Workload Identity Federation setup complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "No service account keys were created. Provide these values in Gateways to complete the connection:"
echo ""
echo "  projectId: $PROJECT_ID"
echo "  projectNumber: $PROJECT_NUMBER"
echo "  poolId: $POOL_ID"
echo "  providerId: $PROVIDER_ID"
echo "  serviceAccountEmail: $SERVICE_ACCOUNT_EMAIL"
echo ""
echo "In Gateways: Connect GCP → Complete with Workload Identity Federation → Enter the values above."
echo ""
