# ODF Bucket Configuration — Manual Procedure

Replacing MinIO GUI-driven configuration with ODF (NooBaa MCG) equivalents.
This procedure covers two configurations:

1. **Bucket Notifications** — Send S3 event notifications to Kafka
2. **Object Lifecycle** — Automatic object expiration

> **Prerequisites:**
> - OpenShift cluster with ODF installed and NooBaa in `Ready` state
> - `oc` CLI logged in with cluster-admin privileges
> - Target bucket already exists (created via ObjectBucketClaim or NooBaa CLI)
> - Kafka cluster accessible from the OpenShift cluster

---

## Part 1: Bucket Notifications to Kafka

### Step 1 — Extract MCG credentials and set up the S3 alias

```bash
export NOOBAA_ACCESS_KEY=$(oc extract secret/noobaa-admin -n openshift-storage \
  --keys=AWS_ACCESS_KEY_ID --to=- 2>/dev/null)

export NOOBAA_SECRET_KEY=$(oc extract secret/noobaa-admin -n openshift-storage \
  --keys=AWS_SECRET_ACCESS_KEY --to=- 2>/dev/null)

export S3_ENDPOINT=https://$(oc get route s3 -n openshift-storage -o jsonpath='{.spec.host}')

alias mcg-s3='AWS_ACCESS_KEY_ID=$NOOBAA_ACCESS_KEY \
  AWS_SECRET_ACCESS_KEY=$NOOBAA_SECRET_KEY \
  aws --endpoint "$S3_ENDPOINT" --no-verify-ssl'
```

Verify connectivity:

```bash
mcg-s3 s3 ls
```

### Step 2 — Create the Kafka connection configuration

Create a file named `kafka-connection.json`:

```json
{
  "name": "kafka-notification-connection",
  "notification_protocol": "kafka",
  "kafka_options_object": {
    "metadata.broker.list": "<KAFKA_BOOTSTRAP_SERVER>:<PORT>"
  },
  "topic": "<KAFKA_TOPIC_NAME>"
}
```

> **Important:** The `metadata.broker.list` property must be nested inside
> `kafka_options_object`. This object is passed directly to the rdkafka producer.
> You can add additional rdkafka options here (e.g., `"security.protocol": "sasl_ssl"`).

Replace the placeholders:

| Placeholder | Description | Example |
|---|---|---|
| `<KAFKA_BOOTSTRAP_SERVER>:<PORT>` | Kafka bootstrap server address | `my-cluster-kafka-bootstrap.kafka.svc.cluster.local:9092` |
| `<KAFKA_TOPIC_NAME>` | Kafka topic to receive notifications | `bucket-events` |

### Step 3 — Create a Secret from the connection configuration

```bash
oc create secret generic kafka-notif-connection \
  --from-file=connect.json=kafka-connection.json \
  -n openshift-storage
```

### Step 4 — Patch the NooBaa CR to enable bucket notifications

```bash
oc patch noobaa noobaa -n openshift-storage --type='merge' -p '{
  "spec": {
    "bucketNotifications": {
      "connections": [
        {
          "name": "kafka-notif-connection",
          "namespace": "openshift-storage"
        }
      ],
      "enabled": true
    }
  }
}'
```

Wait for the NooBaa pods to restart:

```bash
oc rollout status statefulset/noobaa-core -n openshift-storage --timeout=120s
oc wait pod -l app=noobaa -n openshift-storage --for=condition=Ready --timeout=120s
```

### Step 5 — Configure bucket notification on the target bucket

```bash
BUCKET_NAME="<YOUR_BUCKET_NAME>"

mcg-s3 s3api put-bucket-notification-configuration \
  --bucket "$BUCKET_NAME" \
  --notification-configuration '{
    "TopicConfigurations": [
      {
        "Id": "kafka-all-events",
        "Events": [
          "s3:ObjectCreated:*",
          "s3:ObjectRemoved:*"
        ],
        "TopicArn": "kafka-notif-connection/connect.json"
      }
    ]
  }'
```

> **Customizing events:** Adjust the `Events` array to match your needs.
> Supported events:
> - `s3:ObjectCreated:*` (Put, Post, Copy, CompleteMultipartUpload)
> - `s3:ObjectRemoved:*` (Delete, DeleteMarkerCreated)
> - `s3:ObjectTagging:*` (Put, Delete)
> - `s3:LifecycleExpiration:*` (Delete, DeleteMarkerCreated)

### Step 6 — Verify the notification configuration

```bash
mcg-s3 s3api get-bucket-notification-configuration --bucket "$BUCKET_NAME"
```

### Step 7 — Test the notification

Upload a test object and verify the event reaches Kafka:

```bash
echo 'test' | mcg-s3 s3 cp - s3://$BUCKET_NAME/test-notification.txt
```

Verify on the Kafka consumer side:

```bash
# If using Strimzi/AMQ Streams on the same cluster:
oc -n <KAFKA_NAMESPACE> exec -it <KAFKA_POD> -- \
  bin/kafka-console-consumer.sh \
  --bootstrap-server <KAFKA_BOOTSTRAP_SERVER>:<PORT> \
  --topic <KAFKA_TOPIC_NAME> \
  --from-beginning --timeout-ms 10000
```

Expected output:

```json
{
  "Records": [
    {
      "eventVersion": "2.3",
      "eventSource": "noobaa:s3",
      "eventName": "ObjectCreated:Put",
      "s3": {
        "bucket": { "name": "<YOUR_BUCKET_NAME>" },
        "object": { "key": "test-notification.txt" }
      }
    }
  ]
}
```

Clean up the test object:

```bash
mcg-s3 s3 rm s3://$BUCKET_NAME/test-notification.txt
```

---

## Part 2: Object Lifecycle — Automatic Expiration

### Step 1 — Ensure MCG credentials are set

If not already done, run the credential extraction from Part 1, Step 1.

### Step 2 — Configure lifecycle expiration on the bucket

```bash
BUCKET_NAME="<YOUR_BUCKET_NAME>"

# ┌─────────────────────────────────────────────────────┐
# │  CONFIGURE EXPIRATION DAYS BELOW                    │
# │  Change the value of "Days" to match your           │
# │  retention requirements.                            │
# │  Current setting: 7 days                            │
# └─────────────────────────────────────────────────────┘
EXPIRATION_DAYS=7

mcg-s3 s3api put-bucket-lifecycle-configuration \
  --bucket "$BUCKET_NAME" \
  --lifecycle-configuration "{
    \"Rules\": [
      {
        \"ID\": \"auto-expire-objects\",
        \"Status\": \"Enabled\",
        \"Filter\": {
          \"Prefix\": \"\"
        },
        \"Expiration\": {
          \"Days\": $EXPIRATION_DAYS
        }
      }
    ]
  }"
```

> **Customizing the lifecycle rule:**
>
> | Parameter | Description | Example |
> |---|---|---|
> | `EXPIRATION_DAYS` | Number of days before objects are automatically deleted | `7`, `30`, `90` |
> | `Filter.Prefix` | Apply rule only to objects with this key prefix. Empty string (`""`) applies to all objects | `"logs/"`, `"raw-data/"` |
> | `ID` | Human-readable name for the rule | `"expire-logs-7d"` |
>
> **Multiple rules example** — different retention per prefix:
>
> ```bash
> mcg-s3 s3api put-bucket-lifecycle-configuration \
>   --bucket "$BUCKET_NAME" \
>   --lifecycle-configuration '{
>     "Rules": [
>       {
>         "ID": "expire-raw-data-7d",
>         "Status": "Enabled",
>         "Filter": { "Prefix": "raw/" },
>         "Expiration": { "Days": 7 }
>       },
>       {
>         "ID": "expire-processed-data-30d",
>         "Status": "Enabled",
>         "Filter": { "Prefix": "processed/" },
>         "Expiration": { "Days": 30 }
>       }
>     ]
>   }'
> ```

### Step 3 — Verify the lifecycle configuration

```bash
mcg-s3 s3api get-bucket-lifecycle-configuration --bucket "$BUCKET_NAME"
```

Expected output:

```json
{
    "Rules": [
        {
            "ID": "auto-expire-objects",
            "Status": "Enabled",
            "Filter": {
                "Prefix": ""
            },
            "Expiration": {
                "Days": 7
            }
        }
    ]
}
```

### Step 4 — (Optional) Remove lifecycle configuration

To remove a lifecycle policy from a bucket:

```bash
mcg-s3 s3api delete-bucket-lifecycle --bucket "$BUCKET_NAME"
```

---

## Quick Reference

| Action | Command |
|---|---|
| List buckets | `mcg-s3 s3 ls` |
| Get notification config | `mcg-s3 s3api get-bucket-notification-configuration --bucket BUCKET` |
| Set notification config | `mcg-s3 s3api put-bucket-notification-configuration --bucket BUCKET --notification-configuration '...'` |
| Remove notification config | `mcg-s3 s3api put-bucket-notification-configuration --bucket BUCKET --notification-configuration '{}'` |
| Get lifecycle config | `mcg-s3 s3api get-bucket-lifecycle-configuration --bucket BUCKET` |
| Set lifecycle config | `mcg-s3 s3api put-bucket-lifecycle-configuration --bucket BUCKET --lifecycle-configuration '...'` |
| Remove lifecycle config | `mcg-s3 s3api delete-bucket-lifecycle --bucket BUCKET` |
