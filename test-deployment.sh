#!/bin/bash
set -uo pipefail

# Smoke test for ODF bucket notification to Kafka.
# Uploads a test object to the bucket and verifies the event arrives in Kafka.
#
# Usage:
#   ./test-deployment.sh --bucket <BUCKET_NAME> --topic <KAFKA_TOPIC>
#
# Optional:
#   --kafka-bootstrap <HOST:PORT>   Kafka bootstrap (default: auto-detect from Kafka CR)
#   --kafka-ns <NAMESPACE>          Kafka namespace (default: odf-bucket-demo)
#   --kafka-cluster <NAME>          Kafka cluster name (default: demo-kafka)
#   --s3-endpoint <URL>             S3 endpoint (default: auto-detect from NooBaa route)
#   --access-key <KEY>              S3 access key (default: auto-extract from noobaa-admin secret)
#   --secret-key <KEY>              S3 secret key (default: auto-extract from noobaa-admin secret)
#   --timeout <SECONDS>             Kafka consumer timeout (default: 15)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

BUCKET_NAME=""
KAFKA_TOPIC=""
KAFKA_NS="odf-bucket-demo"
KAFKA_CLUSTER="demo-kafka"
KAFKA_BOOTSTRAP=""
S3_ENDPOINT=""
ACCESS_KEY=""
SECRET_KEY=""
TIMEOUT=15

while [[ $# -gt 0 ]]; do
  case $1 in
    --bucket)           BUCKET_NAME="$2"; shift 2 ;;
    --topic)            KAFKA_TOPIC="$2"; shift 2 ;;
    --kafka-bootstrap)  KAFKA_BOOTSTRAP="$2"; shift 2 ;;
    --kafka-ns)         KAFKA_NS="$2"; shift 2 ;;
    --kafka-cluster)    KAFKA_CLUSTER="$2"; shift 2 ;;
    --s3-endpoint)      S3_ENDPOINT="$2"; shift 2 ;;
    --access-key)       ACCESS_KEY="$2"; shift 2 ;;
    --secret-key)       SECRET_KEY="$2"; shift 2 ;;
    --timeout)          TIMEOUT="$2"; shift 2 ;;
    -h|--help)
      sed -n '3,16p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$BUCKET_NAME" || -z "$KAFKA_TOPIC" ]]; then
  echo -e "${RED}Error:${NC} --bucket and --topic are required."
  echo "Usage: $0 --bucket <BUCKET_NAME> --topic <KAFKA_TOPIC>"
  exit 1
fi

# ── Auto-detect defaults ──────────────────────────────────────────
if [[ -z "$ACCESS_KEY" ]]; then
  ACCESS_KEY=$(oc extract secret/noobaa-admin -n openshift-storage --keys=AWS_ACCESS_KEY_ID --to=- 2>/dev/null)
fi
if [[ -z "$SECRET_KEY" ]]; then
  SECRET_KEY=$(oc extract secret/noobaa-admin -n openshift-storage --keys=AWS_SECRET_ACCESS_KEY --to=- 2>/dev/null)
fi
if [[ -z "$S3_ENDPOINT" ]]; then
  S3_ENDPOINT=https://$(oc get route s3 -n openshift-storage -o jsonpath='{.spec.host}')
fi
if [[ -z "$KAFKA_BOOTSTRAP" ]]; then
  KAFKA_BOOTSTRAP="${KAFKA_CLUSTER}-kafka-bootstrap.${KAFKA_NS}.svc.cluster.local:9092"
fi

# Find Kafka pod
KAFKA_POD=""
for pod in "${KAFKA_CLUSTER}-combined-0" "${KAFKA_CLUSTER}-kafka-0"; do
  if oc get pod "$pod" -n "$KAFKA_NS" &>/dev/null; then
    KAFKA_POD="$pod"
    break
  fi
done
if [[ -z "$KAFKA_POD" ]]; then
  echo -e "${RED}Error:${NC} No Kafka pod found in namespace $KAFKA_NS"
  exit 1
fi

s3() {
  AWS_ACCESS_KEY_ID=$ACCESS_KEY AWS_SECRET_ACCESS_KEY=$SECRET_KEY \
    aws --endpoint "$S3_ENDPOINT" --no-verify-ssl "$@" 2>&1 | grep -vE 'InsecureRequestWarning|warnings\.warn' || true
}

# ── Test ──────────────────────────────────────────────────────────
TEST_KEY="smoke-test-$(date +%s).txt"
TIMEOUT_MS=$((TIMEOUT * 1000))

echo -e "${YELLOW}Bucket:${NC}  $BUCKET_NAME"
echo -e "${YELLOW}Topic:${NC}   $KAFKA_TOPIC"
echo -e "${YELLOW}Object:${NC}  $TEST_KEY"
echo ""

echo -n "Uploading test object... "
UPLOAD=$(echo "smoke-test-payload-$(date -Iseconds)" | s3 s3 cp - "s3://$BUCKET_NAME/$TEST_KEY")
if [[ "$UPLOAD" == *"upload:"* ]] || s3 s3api head-object --bucket "$BUCKET_NAME" --key "$TEST_KEY" &>/dev/null; then
  echo -e "${GREEN}OK${NC}"
else
  echo -e "${RED}FAILED${NC}"
  exit 1
fi

echo -n "Waiting for Kafka event (${TIMEOUT}s)... "
KAFKA_OUTPUT=$(oc exec -n "$KAFKA_NS" "$KAFKA_POD" -- \
  bin/kafka-console-consumer.sh \
  --bootstrap-server "$KAFKA_BOOTSTRAP" \
  --topic "$KAFKA_TOPIC" \
  --from-beginning \
  --timeout-ms "$TIMEOUT_MS" 2>/dev/null || true)

if [[ "$KAFKA_OUTPUT" == *"$TEST_KEY"* ]]; then
  echo -e "${GREEN}OK${NC} — event received"
else
  echo -e "${RED}FAILED${NC} — no event found for $TEST_KEY"
  echo "Cleaning up..."
  s3 s3 rm "s3://$BUCKET_NAME/$TEST_KEY" >/dev/null 2>&1
  exit 1
fi

echo -n "Cleaning up... "
s3 s3 rm "s3://$BUCKET_NAME/$TEST_KEY" >/dev/null 2>&1
echo -e "${GREEN}OK${NC}"

echo ""
echo -e "${GREEN}Test passed.${NC} Bucket notification to Kafka is working."
