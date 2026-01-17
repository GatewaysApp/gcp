#!/bin/bash
# Deplo GCP Connection Setup Script
# This script creates a service account with all necessary IAM roles for Deplo
# Run this in Google Cloud Shell or locally with gcloud CLI installed

set -e

# Configuration
SERVICE_ACCOUNT_ID="deplo-cloud-connection"
SERVICE_ACCOUNT_NAME="Deplo Cloud Connection Service Account"
SERVICE_ACCOUNT_DESCRIPTION="Service account that allows Deplo SaaS platform to deploy and manage resources"

# Get current project ID
PROJECT_ID=$(gcloud config get-value project)

if [ -z "$PROJECT_ID" ]; then
  echo "❌ Error: No GCP project selected. Please run: gcloud config set project YOUR_PROJECT_ID"
  exit 1
fi

echo "🔧 Setting up Deplo GCP connection for project: $PROJECT_ID"
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
  "roles/compute.admin"           # Compute Engine Admin (for VMs, disks, networking)
  "roles/storage.admin"           # Storage Admin (for Cloud Storage)
  "roles/cloudsql.admin"          # Cloud SQL Admin (for databases)
  "roles/iam.serviceAccountUser"  # Service Account User (to impersonate service accounts)
  "roles/compute.networkAdmin"    # Network Admin (for VPC, firewall rules, load balancers)
  "roles/viewer"                  # Project Viewer (for reading project information)
  "roles/dns.admin"               # DNS Admin (for managing DNS zones and records)
  "roles/cloudfunctions.admin"    # Cloud Functions Admin (for serverless functions)
  "roles/run.admin"               # Cloud Run Admin (for containerized applications)
  "roles/secretmanager.admin"     # Secret Manager Admin (for managing secrets)
)

for ROLE in "${ROLES[@]}"; do
  echo "  - Granting $ROLE..."
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
    --role="$ROLE" \
    --condition=None \
    --quiet &>/dev/null || true
done

echo "✅ All roles granted successfully"
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

KEY_FILE="deplo-service-account-key-$(date +%s).json"
gcloud iam service-accounts keys create "$KEY_FILE" \
  --iam-account="$SERVICE_ACCOUNT_EMAIL" \
  --format=json

# Check if key creation was successful
if [ ! -f "$KEY_FILE" ] || [ ! -s "$KEY_FILE" ]; then
  echo "❌ Error: Failed to create service account key"
  echo "Please check:"
  echo "  1. The service account exists: $SERVICE_ACCOUNT_EMAIL"
  echo "  2. You have permissions to create service account keys"
  echo "  3. The service account doesn't have 10 keys already (maximum limit)"
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
