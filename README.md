# ODF Bucket Configuration

Replacing MinIO GUI-driven bucket management with ODF (NooBaa MCG) equivalents for:

- **Bucket Notifications** — S3 event notifications to Kafka
- **Object Lifecycle** — Automatic object expiration

## Contents

| Path | Description |
|---|---|
| `manual-procedure.md` | Step-by-step manual procedure for the edge team |
| `crossplane-poc/` | Crossplane GitOps-driven configuration (provider-aws-s3 against NooBaa) |
| `crossplane-poc/disconnected-install.md` | Air-gapped / private network installation guide |
| `test-deployment.sh` | Smoke test — uploads an object and verifies Kafka notification |

## Smoke Test

Verifies end-to-end that uploading an object to the bucket triggers a notification event in Kafka.

```bash
./test-deployment.sh --bucket <BUCKET_NAME> --topic <KAFKA_TOPIC>
```

S3 credentials and Kafka pod are auto-detected from the cluster. Override with flags if needed:

```
--s3-endpoint <URL>             S3 endpoint (default: NooBaa route)
--access-key <KEY>              S3 access key (default: noobaa-admin secret)
--secret-key <KEY>              S3 secret key (default: noobaa-admin secret)
--kafka-bootstrap <HOST:PORT>   Kafka bootstrap address
--kafka-ns <NAMESPACE>          Kafka namespace (default: odf-bucket-demo)
--kafka-cluster <NAME>          Kafka cluster name (default: demo-kafka)
--timeout <SECONDS>             Kafka consumer timeout (default: 15)
```

Example:

```bash
# Get bucket name from OBC
BUCKET=$(oc get obc my-bucket -n my-ns -o jsonpath='{.spec.bucketName}')

# Run test
./test-deployment.sh --bucket $BUCKET --topic bucket-events
```

## Prerequisites

- OpenShift cluster with ODF installed (NooBaa in Ready state)
- `oc` CLI logged in with cluster-admin
- `aws` CLI installed
- Kafka cluster accessible from OpenShift
