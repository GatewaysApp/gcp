#!/bin/bash
# Gateways GCP Connection Setup Script
# This script creates a service account with all necessary IAM roles for Gateways
# Run this in Google Cloud Shell or locally with gcloud CLI installed

# Don't exit on errors - we'll handle them manually
set +e

# Configuration
SERVICE_ACCOUNT_ID="gateways-cloud-connection"
SERVICE_ACCOUNT_NAME="Gateways Cloud Connection Service Account"
SERVICE_ACCOUNT_DESCRIPTION="Service account that allows Gateways to deploy and manage GCP resources"

# Get current project ID
PROJECT_ID=$(gcloud config get-value project)

if [ -z "$PROJECT_ID" ]; then
  echo "❌ Error: No GCP project selected. Please run: gcloud config set project YOUR_PROJECT_ID"
  exit 1
fi

echo "🔧 Setting up Deplo GCP connection for project: $PROJECT_ID"
echo ""

# Enable required GCP APIs
echo "🔌 Enabling required GCP APIs..."
APIS=(
  "compute.googleapis.com"           # Compute Engine API (for VMs, firewall rules, networking)
  "cloudresourcemanager.googleapis.com"  # Cloud Resource Manager API (for project operations)
  "iam.googleapis.com"               # Identity and Access Management API (for service accounts)
  "storage.googleapis.com"           # Cloud Storage API (for storage buckets)
  "sqladmin.googleapis.com"          # Cloud SQL Admin API (for databases)
  "dns.googleapis.com"               # Cloud DNS API (for DNS management)
  "cloudfunctions.googleapis.com"    # Cloud Functions API (for serverless functions)
  "cloudbuild.googleapis.com"        # Cloud Build API (required for Cloud Functions deployment)
  "run.googleapis.com"               # Cloud Run API (for containerized applications)
  "secretmanager.googleapis.com"     # Secret Manager API (for secrets)
  "redis.googleapis.com"             # Memorystore for Redis API (for cache servers)
)

BILLING_REQUIRED=false

# Check which APIs are already enabled to avoid unnecessary attempts
echo "🔍 Checking currently enabled APIs..."
ENABLED_APIS=$(gcloud services list --enabled --project="$PROJECT_ID" --format="value(config.name)" 2>/dev/null || echo "")

for API in "${APIS[@]}"; do
  echo "  - Enabling $API..."
  
  # Check if API is already enabled
  if echo "$ENABLED_APIS" | grep -q "^$API$"; then
    echo "    ✅ $API already enabled"
    continue
  fi
  
  # Try to enable the API and capture output
  OUTPUT=$(gcloud services enable "$API" --project="$PROJECT_ID" 2>&1)
  EXIT_CODE=$?
  
  if [ $EXIT_CODE -eq 0 ]; then
    # Success - API enabled
    echo "    ✅ $API enabled successfully"
  else
    # Command failed - check error type
    if echo "$OUTPUT" | grep -qi "billing\|BILLING_NOT_OPEN\|UREQ_PROJECT_BILLING_NOT_OPEN"; then
      echo "    ⚠️  Failed: Billing account not enabled for this project"
      echo "       Compute Engine API requires billing to be enabled."
      echo "       Please enable billing at:"
      echo "       https://console.cloud.google.com/billing/linkedaccount?project=$PROJECT_ID"
      BILLING_REQUIRED=true
    elif echo "$OUTPUT" | grep -qi "PERMISSION_DENIED\|access denied\|forbidden"; then
      echo "    ⚠️  Failed: Insufficient permissions to enable $API"
      echo "       Please ensure you have 'Service Usage Admin' role or enable it manually:"
      echo "       https://console.developers.google.com/apis/library/$API?project=$PROJECT_ID"
    elif echo "$OUTPUT" | grep -qi "already enabled"; then
      echo "    ✅ $API already enabled"
    else
      ERROR_MSG=$(echo "$OUTPUT" | grep -i "ERROR:" | head -1 || echo "$OUTPUT" | head -1)
      echo "    ⚠️  Failed to enable $API"
      if [ -n "$ERROR_MSG" ]; then
        echo "       $ERROR_MSG"
      fi
      echo "       You can manually enable it at:"
      echo "       https://console.developers.google.com/apis/library/$API?project=$PROJECT_ID"
    fi
  fi
done

echo "✅ API enablement completed"
echo ""

if [ "$BILLING_REQUIRED" = true ]; then
  echo "⚠️  IMPORTANT: Billing must be enabled for Compute Engine API"
  echo ""
  echo "   To enable billing:"
  echo "   1. Visit: https://console.cloud.google.com/billing/linkedaccount?project=$PROJECT_ID"
  echo "   2. Link a billing account to your project"
  echo "   3. Wait a few minutes for billing to activate"
  echo "   4. Re-run this script to enable the remaining APIs"
  echo ""
  echo "   Note: Compute Engine API (and some other APIs) require billing to be enabled."
  echo "   Once billing is enabled, you can re-run this script to complete the setup."
  echo ""
fi

echo "ℹ️  Note: If any APIs failed to enable:"
if [ "$BILLING_REQUIRED" = false ]; then
  echo "   1. Ensure billing is enabled for your GCP project (some APIs require it)"
fi
echo "   - Check that you have sufficient permissions (Service Usage Admin role)"
echo "   - Wait a few minutes for changes to propagate"
echo "   - Manually enable APIs from the links shown above if needed"
echo ""

# Check if service account already exists
if gcloud iam service-accounts describe "$SERVICE_ACCOUNT_ID@$PROJECT_ID.iam.gserviceaccount.com" &>/dev/null; then
  echo "⚠️  Service account already exists. Updating roles..."
  SERVICE_ACCOUNT_EMAIL="$SERVICE_ACCOUNT_ID@$PROJECT_ID.iam.gserviceaccount.com"
else
  # Create service account
  echo "📝 Creating service account..."
  SERVICE_ACCOUNT_EMAIL=$(gcloud iam service-accounts create "$SERVICE_ACCOUNT_ID" \
    --display-name="$SERVICE_ACCOUNT_NAME" \
    --description="$SERVICE_ACCOUNT_DESCRIPTION" \
    --format="value(email)")
  echo "✅ Service account created: $SERVICE_ACCOUNT_EMAIL"
fi

echo ""
echo "🔐 Granting IAM roles..."

# Grant roles
ROLES=(
  "roles/compute.admin"           # Compute Engine Admin (VMs, disks, images, instance templates, MIGs, backend services, NEGs, load balancers, CDN backend buckets, SSL certs, golden image deployment)
  "roles/storage.admin"           # Storage Admin (Cloud Storage buckets, objects, and bucket IAM policies for instance/scalable-server ↔ storage connections)
  "roles/cloudsql.admin"          # Cloud SQL Admin (databases, authorized networks for instance/function/scalable-server ↔ database connections)
  "roles/iam.serviceAccountUser"  # Service Account User (to impersonate service accounts)
  "roles/compute.networkAdmin"    # Network Admin (VPC, firewall rules, network connections between resources)
  "roles/viewer"                  # Project Viewer (for reading project information)
  "roles/dns.admin"               # DNS Admin (Cloud DNS zones and records for dns ↔ resource connections)
  "roles/cloudfunctions.admin"    # Cloud Functions Admin (for serverless functions)
  "roles/run.admin"               # Cloud Run Admin (for containerized applications)
  "roles/secretmanager.admin"     # Secret Manager Admin (for managing secrets)
  "roles/redis.admin"             # Memorystore for Redis Admin (cache servers, scalable server → cache connections)
)

for ROLE in "${ROLES[@]}"; do
  echo "  - Granting $ROLE..."
  if gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
    --role="$ROLE" \
    --condition=None \
    --quiet 2>&1; then
    echo "    ✅ $ROLE granted successfully"
  else
    echo "    ⚠️  Warning: Failed to grant $ROLE (may already be granted or need manual permission)"
  fi
done

echo "✅ Role granting completed"
echo ""
echo "⏳ Waiting for IAM permissions to propagate (this may take a few seconds)..."
sleep 5

# Verify that viewer role is granted (required for basic access)
echo "🔍 Verifying permissions..."
HAS_VIEWER=$(gcloud projects get-iam-policy "$PROJECT_ID" \
  --flatten="bindings[].members" \
  --format="value(bindings.role)" \
  --filter="bindings.members:serviceAccount:$SERVICE_ACCOUNT_EMAIL AND bindings.role:roles/viewer" 2>/dev/null | head -1)

if [ -z "$HAS_VIEWER" ]; then
  echo "⚠️  Warning: Viewer role not detected. This may cause permission issues."
  echo "   Please manually grant 'roles/viewer' to: $SERVICE_ACCOUNT_EMAIL"
else
  echo "✅ Viewer role confirmed"
fi
echo ""

# Create and download service account key
echo "🔑 Creating service account key..."

# Check if service account has maximum keys (10 is the limit)
KEY_COUNT=$(gcloud iam service-accounts keys list --iam-account="$SERVICE_ACCOUNT_EMAIL" --format="value(name)" 2>/dev/null | wc -l | tr -d ' ')

if [ "$KEY_COUNT" -ge 10 ]; then
  echo "⚠️  Service account has $KEY_COUNT keys (maximum is 10). Deleting oldest keys..."
  
  # Get list of keys sorted by creation time (oldest first) and delete oldest ones
  # Keep only the 8 most recent keys to make room for new one
  KEYS_TO_DELETE=$(gcloud iam service-accounts keys list \
    --iam-account="$SERVICE_ACCOUNT_EMAIL" \
    --format="value(name)" \
    --sort-by=~validAfterTime 2>/dev/null | tail -n +9)
  
  if [ -n "$KEYS_TO_DELETE" ]; then
    echo "$KEYS_TO_DELETE" | while read -r key_id; do
      if [ -n "$key_id" ]; then
        echo "  - Deleting old key: $key_id"
        gcloud iam service-accounts keys delete "$key_id" \
          --iam-account="$SERVICE_ACCOUNT_EMAIL" \
          --quiet 2>/dev/null || true
      fi
    done
  fi
  
  # Wait a moment for deletion to propagate
  sleep 2
fi

# If service account was just created, wait a moment for it to propagate
if [ "$KEY_COUNT" -eq 0 ]; then
  echo "⏳ Waiting for service account to propagate..."
  sleep 3
fi

KEY_FILE="gateways-service-account-key-$(date +%s).json"
KEY_CREATE_OUTPUT=$(gcloud iam service-accounts keys create "$KEY_FILE" \
  --iam-account="$SERVICE_ACCOUNT_EMAIL" \
  --format=json 2>&1)
KEY_CREATE_EXIT=$?

# Check if key creation failed due to org policy (disableServiceAccountKeyCreation)
if [ $KEY_CREATE_EXIT -ne 0 ]; then
  if echo "$KEY_CREATE_OUTPUT" | grep -q "disableServiceAccountKeyCreation"; then
    echo "❌ Error: Key creation is disabled by your organization's security policy."
    echo ""
    echo "Your GCP project/organization has 'iam.disableServiceAccountKeyCreation' enabled."
    echo "This prevents creating service account keys via gcloud or the Console."
    echo ""
    echo "Options to resolve:"
    echo "  1. Request an exception: Ask your GCP org admin to add an exception for this"
    echo "     project or service account in IAM & Admin → Organization policies."
    echo "  2. Create key manually: If you have Console access, try IAM & Admin →"
    echo "     Service Accounts → $SERVICE_ACCOUNT_EMAIL → Keys → Add key → JSON."
    echo "     (May also be blocked by the same policy.)"
    echo "  3. Use a different project: Use a GCP project that does not have this"
    echo "     constraint (e.g. a personal project) to create the key."
    echo ""
    echo "Service account (roles already granted): $SERVICE_ACCOUNT_EMAIL"
    exit 1
  fi
fi

# Check if key creation was successful
if [ ! -f "$KEY_FILE" ] || [ ! -s "$KEY_FILE" ]; then
  echo "❌ Error: Failed to create service account key"
  echo "$KEY_CREATE_OUTPUT" | head -20
  echo ""
  echo "Please check:"
  echo "  1. The service account exists: $SERVICE_ACCOUNT_EMAIL"
  echo "  2. You have permissions to create service account keys"
  echo "  3. The service account doesn't have 10 keys already (maximum limit)"
  echo "  4. Your org does not block key creation (iam.disableServiceAccountKeyCreation)"
  exit 1
fi

echo ""
echo "✅ Setup completed successfully!"
echo ""
echo "📋 Connection Details:"
echo "  Project ID: $PROJECT_ID"
echo "  Service Account Email: $SERVICE_ACCOUNT_EMAIL"
echo ""

# Base64 encoding function
base64_encode() {
  local input="$1"
  
  # Check if input is provided
  if [ -z "$input" ]; then
    echo "ERROR: Empty input to base64_encode" >&2
    return 1
  fi
  
  # Use base64 command (standard and available everywhere)
  printf "%s" "$input" | base64 -w 0 2>/dev/null || printf "%s" "$input" | base64
}

# Read KEY_FILE content and encode to base64
KEY_FILE_CONTENT=$(cat "$KEY_FILE")

# Check if KEY_FILE has content
if [ -z "$KEY_FILE_CONTENT" ]; then
  echo "❌ Error: Service account key file is empty"
  echo "Please check that the key file was created successfully: $KEY_FILE"
  exit 1
fi

# Encode to base64
echo "📝 Encoding service account key to base64..."
KEY_FILE_BASE64=$(base64_encode "$KEY_FILE_CONTENT")

# Check if encoding was successful
if [ -z "$KEY_FILE_BASE64" ]; then
  echo "❌ Error: Base64 encoding failed (empty result)"
  echo "Please check that the key file is valid JSON"
  exit 1
fi

echo ""
echo "🔐 Key File (Base64 Encoded): Copy this and provide in 'Service Account Key' field to complete cloud connection"
echo "$KEY_FILE_BASE64"

# Delete the KEY_FILE
rm -f "$KEY_FILE"
echo ""
echo "⚠️  Keep the service account key secure and never commit it to version control!"
