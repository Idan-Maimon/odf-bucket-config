#!/bin/bash
set -euo pipefail

# Crossplane POC Setup for ODF Bucket Configuration
# This script automates the Crossplane setup against NooBaa MCG.

NAMESPACE="crossplane-system"
ODF_NAMESPACE="openshift-storage"

echo "=== Step 1: Install Crossplane via OLM ==="
oc apply -f base/namespace.yaml
oc apply -f base/install.yaml

echo "Waiting for Crossplane operator to be ready..."
sleep 30
oc wait --for=condition=Available deployment/crossplane -n "$NAMESPACE" --timeout=300s 2>/dev/null || \
  echo "Waiting for Crossplane deployment... check 'oc get csv -n openshift-operators' if this takes too long"

echo ""
echo "=== Step 2: Install AWS S3 Provider ==="
oc apply -f provider/aws-s3-provider.yaml

echo "Waiting for provider to become healthy..."
sleep 20
oc wait --for=condition=Healthy provider/provider-aws-s3 --timeout=300s 2>/dev/null || \
  echo "Provider still installing... check 'oc get provider' for status"

echo ""
echo "=== Step 3: Configure Provider with NooBaa Credentials ==="

# Extract NooBaa credentials
NOOBAA_ACCESS_KEY=$(oc extract secret/noobaa-admin -n "$ODF_NAMESPACE" \
  --keys=AWS_ACCESS_KEY_ID --to=- 2>/dev/null)
NOOBAA_SECRET_KEY=$(oc extract secret/noobaa-admin -n "$ODF_NAMESPACE" \
  --keys=AWS_SECRET_ACCESS_KEY --to=- 2>/dev/null)
S3_ROUTE=$(oc get route s3 -n "$ODF_NAMESPACE" -o jsonpath='{.spec.host}')

# Create the credentials secret
oc create secret generic noobaa-s3-credentials \
  -n "$NAMESPACE" \
  --from-literal=credentials="[default]
aws_access_key_id = $NOOBAA_ACCESS_KEY
aws_secret_access_key = $NOOBAA_SECRET_KEY" \
  --dry-run=client -o yaml | oc apply -f -

# Apply provider config with the correct S3 endpoint
sed "s|https://s3-openshift-storage.apps.ocp.ptgzp.sandbox3640.opentlc.com|https://$S3_ROUTE|g" \
  provider/provider-config.yaml | oc apply -f -

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  1. Edit resources/bucket-notification.yaml — set your bucket name and Kafka topic ARN"
echo "  2. Edit resources/bucket-lifecycle.yaml — set your bucket name and expiration days"
echo "  3. Apply: oc apply -f resources/"
echo ""
echo "NooBaa S3 Endpoint: https://$S3_ROUTE"
