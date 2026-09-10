#!/bin/bash
set -euo pipefail

# Crossplane POC Setup for ODF Bucket Configuration
# Installs Crossplane via Helm and configures it against NooBaa MCG.
#
# Prerequisites:
#   - oc CLI logged in with cluster-admin
#   - helm v3 installed
#   - ODF deployed with NooBaa in Ready state

NAMESPACE="crossplane-system"
ODF_NAMESPACE="openshift-storage"
CROSSPLANE_VERSION="2.4.0"
PROVIDER_VERSION="v1.20.0"

echo "=== Step 1: Install Crossplane via Helm ==="
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update

oc create namespace "$NAMESPACE" --dry-run=client -o yaml | oc apply -f -

helm upgrade --install crossplane crossplane-stable/crossplane \
  --namespace "$NAMESPACE" \
  --version "$CROSSPLANE_VERSION" \
  --wait

echo "=== Step 2: Grant OpenShift SCCs ==="
oc adm policy add-scc-to-user anyuid -z crossplane -n "$NAMESPACE"
oc adm policy add-scc-to-user anyuid -z rbac-manager -n "$NAMESPACE"

# Restart pods to pick up SCCs
oc delete pod -l app=crossplane -n "$NAMESPACE" --ignore-not-found
oc delete pod -l app=rbac-manager -n "$NAMESPACE" --ignore-not-found
sleep 5
oc wait --for=condition=Available deployment/crossplane -n "$NAMESPACE" --timeout=120s
oc wait --for=condition=Available deployment/crossplane-rbac-manager -n "$NAMESPACE" --timeout=120s

echo ""
echo "=== Step 3: Install AWS S3 Provider ==="
oc apply -f provider/aws-s3-provider.yaml

echo "Waiting for provider to become healthy..."
sleep 30

# Grant SCCs to provider service accounts
for sa in $(oc get sa -n "$NAMESPACE" -o name | grep -E 'provider-aws-s3|upbound-provider-family-aws'); do
  oc adm policy add-scc-to-user anyuid "$sa" -n "$NAMESPACE" 2>/dev/null || true
done

# Restart provider pods to pick up SCCs
oc delete pod -l pkg.crossplane.io/revision -n "$NAMESPACE" --ignore-not-found
sleep 10

oc wait --for=condition=Healthy provider/provider-aws-s3 --timeout=300s
echo "Provider is healthy."

echo ""
echo "=== Step 4: Configure Provider with NooBaa Credentials ==="

NOOBAA_ACCESS_KEY=$(oc extract secret/noobaa-admin -n "$ODF_NAMESPACE" \
  --keys=AWS_ACCESS_KEY_ID --to=- 2>/dev/null)
NOOBAA_SECRET_KEY=$(oc extract secret/noobaa-admin -n "$ODF_NAMESPACE" \
  --keys=AWS_SECRET_ACCESS_KEY --to=- 2>/dev/null)
S3_ROUTE=$(oc get route s3 -n "$ODF_NAMESPACE" -o jsonpath='{.spec.host}')

oc create secret generic noobaa-s3-credentials \
  -n "$NAMESPACE" \
  --from-literal=credentials="[default]
aws_access_key_id = $NOOBAA_ACCESS_KEY
aws_secret_access_key = $NOOBAA_SECRET_KEY" \
  --dry-run=client -o yaml | oc apply -f -

sed "s|<S3_ROUTE>|$S3_ROUTE|g" provider/provider-config.yaml | oc apply -f -

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  1. Edit resources/bucket-notification.yaml — set your bucket name"
echo "  2. Edit resources/bucket-lifecycle.yaml — set your bucket name and expiration days"
echo "  3. Apply: oc apply -f resources/"
echo ""
echo "NooBaa S3 Endpoint: https://$S3_ROUTE"
