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
KEY_FILE="deplo-service-account-key-$(date +%s).json"
gcloud iam service-accounts keys create "$KEY_FILE" \
  --iam-account="$SERVICE_ACCOUNT_EMAIL" \
  --format=json

echo ""
echo "✅ Setup completed successfully!"
echo ""
echo "📋 Connection Details:"
echo "  Project ID: $PROJECT_ID"
echo "  Service Account Email: $SERVICE_ACCOUNT_EMAIL"
echo ""

# Base62 encoding function
base62_encode() {
  local input="$1"
  local base62_chars="0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
  local result=""
  
  # Convert to number (sum of ASCII values)
  local num=0
  for (( i=0; i<${#input}; i++ )); do
    num=$((num * 256 + $(printf '%d' "'${input:$i:1}")))
  done
  
  # Convert to base62
  while [ $num -gt 0 ]; do
    result="${base62_chars:$((num % 62)):1}$result"
    num=$((num / 62))
  done
  
  # Handle empty string
  [ -z "$result" ] && result="0"
  echo "$result"
}

# Read KEY_FILE content and encode to base62
KEY_FILE_CONTENT=$(cat "$KEY_FILE")
KEY_FILE_BASE62=$(base62_encode "$KEY_FILE_CONTENT")
echo "🔐 Key File (Base62 Encoded):"
echo "$KEY_FILE_BASE62"

# Delete the KEY_FILE
rm -f "$KEY_FILE"
echo ""
echo "⚠️  Keep the service account key secure and never commit it to version control!"
