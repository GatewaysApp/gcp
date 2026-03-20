#!/bin/bash
# Gateways GCP Connection Setup - Workload Identity Federation (no service account keys)
# Use this when your org blocks service account key creation (iam.disableServiceAccountKeyCreation)
# Run in Google Cloud Shell or locally with gcloud CLI

set -e

echo "🔧 Gateways GCP Setup (Workload Identity Federation) - starting..."
echo ""

# Check gcloud auth (common in Cloud Shell when opened from a repo - no account selected)
ACTIVE_ACCOUNT=$(gcloud config get-value account 2>/dev/null) || true
if [ -z "$ACTIVE_ACCOUNT" ] || [ "$ACTIVE_ACCOUNT" = "(unset)" ]; then
  echo "❌ Error: No active gcloud account selected."
  echo "   Run: gcloud auth login"
  echo "   Then re-run this script."
  exit 1
fi

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

# Ensure Cloud Resource Manager API is enabled (needed for projects describe)
gcloud services enable cloudresourcemanager.googleapis.com --project="$PROJECT_ID" 2>/dev/null || true

# Get project number (required for WIF)
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)" 2>&1) || true
if [ -z "$PROJECT_NUMBER" ] || ! [[ "$PROJECT_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "❌ Error: Could not get project number for $PROJECT_ID"
  echo "   Run manually to see the error:"
  echo "   gcloud projects describe $PROJECT_ID --format=\"value(projectNumber)\""
  echo ""
  echo "   Common fixes:"
  echo "   - Enable API: gcloud services enable cloudresourcemanager.googleapis.com --project=$PROJECT_ID"
  echo "   - Ensure you have access (roles/viewer or higher on the project)"
  if [ -n "$PROJECT_NUMBER" ]; then
    echo ""
    echo "   gcloud output: $PROJECT_NUMBER"
  fi
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
  echo "     export GCP_OIDC_ISSUER_URL=https://api.gateways.app/api"
  echo "     curl -sSL https://raw.githubusercontent.com/GatewaysApp/gcp/main/gcp-setup-wif.sh | bash"
  echo ""
  if [ -t 0 ]; then
    read -p "Enter Gateways OIDC Issuer URL (e.g. https://api.gateways.app/api): " GCP_OIDC_ISSUER_URL
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
for API in iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com cloudresourcemanager.googleapis.com compute.googleapis.com storage.googleapis.com sqladmin.googleapis.com dns.googleapis.com cloudfunctions.googleapis.com cloudbuild.googleapis.com run.googleapis.com secretmanager.googleapis.com redis.googleapis.com certificatemanager.googleapis.com; do
  if gcloud services enable "$API" --project="$PROJECT_ID" 2>/dev/null; then
    echo "  ✅ $API"
  else
    echo "  ⚠️  $API (may already be enabled)"
  fi
done
echo ""

# Brief pause so newly enabled APIs (e.g. Certificate Manager) are ready for IAM role grants
sleep 5

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
  "roles/certificatemanager.admin"
)
for ROLE in "${ROLES[@]}"; do
  if gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
    --role="$ROLE" \
    --quiet; then
    echo "  ✅ $ROLE"
  else
    echo "  ⚠️  $ROLE failed, retrying in 3s..."
    sleep 3
    if gcloud projects add-iam-policy-binding "$PROJECT_ID" \
      --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
      --role="$ROLE" \
      --quiet; then
      echo "  ✅ $ROLE (on retry)"
    else
      echo "  ❌ $ROLE - run manually: gcloud projects add-iam-policy-binding $PROJECT_ID --member=serviceAccount:$SERVICE_ACCOUNT_EMAIL --role=$ROLE"
    fi
  fi
done
echo "✅ Roles granted"
echo ""

# Cloud Functions 2nd gen uses Cloud Build; the build service account needs roles/cloudbuild.builds.builder
# See: https://cloud.google.com/functions/docs/troubleshooting#build-service-account
echo "🔨 Configuring Cloud Build service account (required for Cloud Functions 2nd gen)..."
DEFAULT_COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$DEFAULT_COMPUTE_SA" \
  --role="roles/cloudbuild.builds.builder" \
  --quiet 2>/dev/null || true
echo "✅ Cloud Build permissions configured"
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
# principalSet with /* allows any principal from the pool to impersonate the service account
# See: https://cloud.google.com/iam/docs/principal-identifiers#workload-identity-pool
POOL_PRINCIPAL="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/*"
echo "🔑 Granting pool impersonation permission..."
if ! gcloud iam service-accounts add-iam-policy-binding "$SERVICE_ACCOUNT_EMAIL" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="$POOL_PRINCIPAL" \
  --quiet 2>&1; then
  echo ""
  echo "⚠️  Failed to add IAM binding. Run this manually (requires Owner or resourcemanager.projects.setIamPolicy):"
  echo "   gcloud iam service-accounts add-iam-policy-binding $SERVICE_ACCOUNT_EMAIL \\"
  echo "     --project=$PROJECT_ID \\"
  echo "     --role=roles/iam.workloadIdentityUser \\"
  echo "     --member='$POOL_PRINCIPAL'"
  exit 1
fi
echo "✅ Impersonation granted"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Workload Identity Federation setup complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "No service account keys were created. Provide these values in Gateways:"
echo ""
echo "Individual values:"
echo "  projectId: $PROJECT_ID"
echo "  projectNumber: $PROJECT_NUMBER"
echo "  poolId: $POOL_ID"
echo "  providerId: $PROVIDER_ID"
echo "  serviceAccountEmail: $SERVICE_ACCOUNT_EMAIL"
echo ""
echo "JSON (copy paste):"
WIF_JSON="{\"projectId\":\"$PROJECT_ID\",\"projectNumber\":\"$PROJECT_NUMBER\",\"poolId\":\"$POOL_ID\",\"providerId\":\"$PROVIDER_ID\",\"serviceAccountEmail\":\"$SERVICE_ACCOUNT_EMAIL\"}"
echo "$WIF_JSON"
echo ""
echo "Base64 (copy paste):"
echo -n "$WIF_JSON" | base64 | tr -d '\n'
echo ""
echo ""
echo "In Gateways: Connect GCP → Workload Identity Federation → Paste the JSON or Base64 above."
echo ""
