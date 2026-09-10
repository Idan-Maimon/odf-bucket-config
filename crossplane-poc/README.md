# Crossplane POC — ODF Bucket Configuration via GitOps

Manages NooBaa MCG bucket notifications (Kafka) and object lifecycle (expiration) using Crossplane managed resources.

## Architecture

```
Git Repo (these YAMLs)
  └─> Crossplane (v2.4.0, Helm install)
        └─> provider-aws-s3 (v1.20.0)
              └─> NooBaa S3 API (via ProviderConfig custom endpoint)
                    ├── BucketNotification → Kafka
                    └── BucketLifecycleConfiguration → 7-day expiration
```

## Directory Structure

```
crossplane-poc/
├── base/
│   ├── namespace.yaml          # crossplane-system namespace
│   └── install.yaml            # Helm install instructions (not OLM)
├── provider/
│   ├── aws-s3-provider.yaml    # Upbound AWS S3 provider
│   └── provider-config.yaml    # ProviderConfig pointing at NooBaa
├── resources/
│   ├── bucket-notification.yaml  # BucketNotification managed resource
│   └── bucket-lifecycle.yaml     # BucketLifecycleConfiguration managed resource
├── setup.sh                    # Automated setup script
└── README.md
```

## Quick Start

```bash
# 1. Login to OpenShift
oc login ...

# 2. Run setup (installs Crossplane, provider, configures NooBaa endpoint)
chmod +x setup.sh
./setup.sh

# 3. Set your bucket name in the resource files
BUCKET_NAME=$(oc get obc <YOUR_OBC> -n <NAMESPACE> -o jsonpath='{.spec.bucketName}')
sed -i "s/<YOUR_BUCKET_NAME>/$BUCKET_NAME/g" resources/*.yaml

# 4. Apply resources
oc apply -f resources/

# 5. Verify
oc get bucketnotification,bucketlifecycleconfiguration
```

## Prerequisites

- OpenShift cluster with ODF installed (NooBaa in Ready state)
- Helm v3
- NooBaa bucket notification connection already configured (see manual-procedure.md, Steps 2-4)
- Kafka cluster accessible from the OpenShift cluster

## OpenShift-Specific Requirements

### Security Context Constraints (SCC)

Crossplane and provider pods run as non-root UIDs (65532/2000) that violate the default `restricted` SCC. The `anyuid` SCC must be granted to:

- `crossplane` (core controller)
- `rbac-manager` (RBAC controller)
- `provider-aws-s3-*` (provider pod SA)
- `upbound-provider-family-aws-*` (family provider SA)

The `setup.sh` script handles this automatically.

### Why Helm Instead of OLM

The community-operators catalog ships Crossplane v1.5.1 (UXP), which is incompatible with Upbound provider-aws-s3 v1.14+. Helm install of Crossplane v2.4.0 is required.

## Key Gotchas

### ProviderConfig Endpoint

The endpoint block **must** include `services: [s3]` and `source: Custom`, otherwise the provider routes requests to AWS S3 instead of NooBaa:

```yaml
endpoint:
  url:
    type: Static
    static: https://<noobaa-s3-route>
  hostnameImmutable: true
  services:
    - s3
  source: Custom
```

### NooBaa Kafka Connection Format

The Kafka broker list must be nested inside `kafka_options_object` in the connection JSON. Red Hat docs show it at the top level, which causes an rdkafka crash. See `manual-procedure.md` for the correct format.

### Region Field

The `region: us-east-1` field is required by the Crossplane provider schema but ignored by NooBaa.
