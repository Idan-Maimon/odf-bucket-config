# Crossplane POC — Disconnected / Air-Gapped Installation

This guide covers deploying the Crossplane POC in a private network with no internet access, using a private container registry.

## Images to Mirror

### Crossplane Core (2 images)

| Image | Used By |
|---|---|
| `xpkg.crossplane.io/crossplane/crossplane:v2.4.0` | Crossplane controller + RBAC manager |
| `docker.io/library/busybox:1.36` | Crossplane init container (used by Helm chart for package cache init) |

### Crossplane Providers (2 images)

| Image | Used By |
|---|---|
| `xpkg.upbound.io/upbound/provider-aws-s3:v1.20.0` | S3 managed resources (BucketNotification, BucketLifecycleConfiguration) |
| `xpkg.upbound.io/upbound/provider-family-aws:v2.7.2` | ProviderConfig, credentials, auto-installed by provider-aws-s3 |

> **Note:** `provider-family-aws` is pulled automatically when `provider-aws-s3` starts.
> Both must be mirrored.

### AMQ Streams / Kafka (if deploying Kafka in the same cluster)

These are Red Hat images and may already be mirrored if AMQ Streams is deployed:

| Image | Used By |
|---|---|
| `registry.redhat.io/amq-streams/kafka-42-rhel9@sha256:f302...` | Kafka broker |
| `registry.redhat.io/amq-streams/strimzi-rhel9-operator@sha256:6bb2...` | Entity operator |

## Step 1 — Mirror Images

From a machine with internet access, pull and push to your private registry:

```bash
PRIVATE_REGISTRY="registry.example.com"

# Crossplane core
skopeo copy \
  docker://xpkg.crossplane.io/crossplane/crossplane:v2.4.0 \
  docker://${PRIVATE_REGISTRY}/crossplane/crossplane:v2.4.0

# Provider images — these are OCI artifacts (xpkg format), not standard Docker images.
# Use skopeo or crane to copy them:
skopeo copy \
  docker://xpkg.upbound.io/upbound/provider-aws-s3:v1.20.0 \
  docker://${PRIVATE_REGISTRY}/upbound/provider-aws-s3:v1.20.0

skopeo copy \
  docker://xpkg.upbound.io/upbound/provider-family-aws:v2.7.2 \
  docker://${PRIVATE_REGISTRY}/upbound/provider-family-aws:v2.7.2
```

If using OpenShift's `oc-mirror` or `ImageContentSourcePolicy`, create a mapping file:

```yaml
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: crossplane-mirrors
spec:
  repositoryDigestMirrors:
    - source: xpkg.crossplane.io/crossplane
      mirrors:
        - registry.example.com/crossplane
    - source: xpkg.upbound.io/upbound
      mirrors:
        - registry.example.com/upbound
```

For OpenShift 4.14+, use `ImageDigestMirrorSet` instead:

```yaml
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: crossplane-mirrors
spec:
  imageDigestMirrors:
    - source: xpkg.crossplane.io/crossplane
      mirrors:
        - registry.example.com/crossplane
    - source: xpkg.upbound.io/upbound
      mirrors:
        - registry.example.com/upbound
```

## Step 2 — Install Crossplane with Private Registry

```bash
PRIVATE_REGISTRY="registry.example.com"

helm upgrade --install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system --create-namespace \
  --version 2.4.0 \
  --set image.repository=${PRIVATE_REGISTRY}/crossplane/crossplane \
  --set image.tag=v2.4.0 \
  --set packageCache.medium="" \
  --wait
```

If the private registry requires authentication, create a pull secret and reference it:

```bash
oc create secret docker-registry crossplane-pull-secret \
  -n crossplane-system \
  --docker-server=${PRIVATE_REGISTRY} \
  --docker-username=<USER> \
  --docker-password=<PASSWORD>

helm upgrade --install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system --create-namespace \
  --version 2.4.0 \
  --set image.repository=${PRIVATE_REGISTRY}/crossplane/crossplane \
  --set image.tag=v2.4.0 \
  --set imagePullSecrets[0].name=crossplane-pull-secret \
  --wait
```

## Step 3 — Install Provider from Private Registry

Update the Provider resource to point to your private registry:

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-aws-s3
spec:
  package: registry.example.com/upbound/provider-aws-s3:v1.20.0
  packagePullSecrets:
    - name: crossplane-pull-secret
```

The family provider is auto-resolved from the same registry prefix. If it fails to
resolve, install it explicitly:

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: upbound-provider-family-aws
spec:
  package: registry.example.com/upbound/provider-family-aws:v2.7.2
  packagePullSecrets:
    - name: crossplane-pull-secret
```

## Step 4 — Helm Chart (Offline)

If Helm cannot reach the chart repo, download the chart from a connected machine:

```bash
# On connected machine
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm pull crossplane-stable/crossplane --version 2.4.0
# Produces: crossplane-2.4.0.tgz

# Copy to disconnected machine, then:
helm install crossplane ./crossplane-2.4.0.tgz \
  --namespace crossplane-system --create-namespace \
  --set image.repository=${PRIVATE_REGISTRY}/crossplane/crossplane \
  --set image.tag=v2.4.0 \
  --wait
```

## Summary of Changes vs Connected Install

| Component | Connected | Disconnected |
|---|---|---|
| Helm chart | `crossplane-stable/crossplane` | Local `.tgz` file |
| Crossplane image | `xpkg.crossplane.io/crossplane/crossplane` | `${PRIVATE_REGISTRY}/crossplane/crossplane` |
| Provider package | `xpkg.upbound.io/upbound/provider-aws-s3` | `${PRIVATE_REGISTRY}/upbound/provider-aws-s3` |
| Family provider | Auto-resolved from `xpkg.upbound.io` | Auto-resolved or explicit from `${PRIVATE_REGISTRY}` |
| Pull secrets | None | `packagePullSecrets` on Provider, `imagePullSecrets` on Helm |
| Image routing | Direct | ICSP/IDMS or explicit registry override |
| NooBaa / ODF | Already on cluster | Already on cluster (deployed via OLM, mirrored separately) |
| ProviderConfig, resources | No change | No change (these are CRDs, no images involved) |
