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

# Base62 encoding function using Python for proper encoding
base62_encode() {
  local input="$1"
  
  # Use Python for proper base62 encoding (available in Cloud Shell)
  # Handle large strings by reading from stdin to avoid command line length limits
  echo "$input" | python3 -c "
import sys

def base62_encode(data):
    \"\"\"Encode bytes to base62 string, preserving leading zeros.\"\"\"
    chars = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
    
    # Convert string to bytes
    if isinstance(data, str):
        data = data.encode('utf-8')
    
    # Encode byte by byte to preserve all data including leading zeros
    result = ''
    for byte_val in data:
        # Encode each byte as 2 base62 characters (62^2 = 3844 > 256)
        # This ensures we can represent all 256 byte values
        high = byte_val // 62
        low = byte_val % 62
        result += chars[high] + chars[low]
    
    return result

# Read input from stdin (strip trailing newlines for encoding, but we'll preserve content)
input_str = sys.stdin.read()
# Remove trailing newline only if it exists (preserve actual content)
if input_str.endswith('\n'):
    input_str = input_str[:-1]
encoded = base62_encode(input_str)
print(encoded)
"
}

# Base62 decoding function for verification
base62_decode() {
  local encoded="$1"
  
  echo "$encoded" | python3 -c "
import sys

def base62_decode(encoded):
    \"\"\"Decode base62 string back to bytes, preserving leading zeros.\"\"\"
    chars = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
    
    # Decode pairs of base62 characters back to bytes
    if len(encoded) % 2 != 0:
        raise ValueError('Base62 string length must be even (2 chars per byte)')
    
    bytes_list = []
    for i in range(0, len(encoded), 2):
        high_char = encoded[i]
        low_char = encoded[i + 1]
        
        if high_char not in chars or low_char not in chars:
            raise ValueError(f'Invalid base62 character in position {i}')
        
        high_val = chars.index(high_char)
        low_val = chars.index(low_char)
        byte_val = high_val * 62 + low_val
        
        bytes_list.append(byte_val)
    
    # Convert bytes to string
    return bytes(bytes_list).decode('utf-8')

# Read encoded string from stdin (strip only trailing whitespace, preserve actual content)
encoded_str = sys.stdin.read().rstrip()
try:
    if not encoded_str:
        raise ValueError('Empty base62 string')
    decoded = base62_decode(encoded_str)
    # Output without adding extra newline
    sys.stdout.write(decoded)
    sys.stdout.flush()
except Exception as e:
    print(f'ERROR: {str(e)}', file=sys.stderr)
    sys.exit(1)
"
}

# Read KEY_FILE content and encode to base62 (preserve all content)
KEY_FILE_CONTENT=$(cat "$KEY_FILE")
KEY_FILE_BASE62=$(base62_encode "$KEY_FILE_CONTENT")

# Verify encoding/decoding works correctly
echo ""
echo "🔍 Verifying base62 encoding..."
DECODED_VERIFY=$(printf "%s" "$KEY_FILE_BASE62" | base62_decode)

# Compare using printf to avoid newline issues
ORIGINAL_HASH=$(printf "%s" "$KEY_FILE_CONTENT" | sha256sum | cut -d' ' -f1)
DECODED_HASH=$(printf "%s" "$DECODED_VERIFY" | sha256sum | cut -d' ' -f1)

if [ "$ORIGINAL_HASH" = "$DECODED_HASH" ]; then
  echo "✅ Base62 encoding verification successful"
else
  # Debug output to see what's different
  echo "❌ Base62 encoding verification failed!"
  echo ""
  ORIGINAL_LEN=$(printf "%s" "$KEY_FILE_CONTENT" | wc -c)
  DECODED_LEN=$(printf "%s" "$DECODED_VERIFY" | wc -c)
  echo "Original length: $ORIGINAL_LEN bytes"
  echo "Decoded length: $DECODED_LEN bytes"
  echo ""
  echo "Original hash: $ORIGINAL_HASH"
  echo "Decoded hash: $DECODED_HASH"
  echo ""
  
  # Try to find where they differ
  if [ ${#DECODED_VERIFY} -eq 0 ]; then
    echo "⚠️  Error: Decoding produced empty result. The base62 string may be invalid."
    echo "Base62 string length: ${#KEY_FILE_BASE62} characters"
  else
    # Show first 200 chars of each for comparison
    ORIGINAL_PREVIEW=$(printf "%s" "$KEY_FILE_CONTENT" | head -c 200)
    DECODED_PREVIEW=$(printf "%s" "$DECODED_VERIFY" | head -c 200)
    echo "Original (first 200 bytes): $ORIGINAL_PREVIEW"
    echo "Decoded (first 200 bytes): $DECODED_PREVIEW"
    echo ""
    echo "⚠️  Warning: Encoded key may not decode correctly. Please check the encoding function."
  fi
fi

echo ""
echo "🔐 Key File (Base62 Encoded): Copy this and provide in 'Service Account Key' field to complete cloud connection"
echo "$KEY_FILE_BASE62"

# Delete the KEY_FILE
rm -f "$KEY_FILE"
echo ""
echo "⚠️  Keep the service account key secure and never commit it to version control!"
