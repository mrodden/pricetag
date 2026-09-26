# PriceTag on OpenShift — Fresh-Environment Deployment Guide

> **PriceTag** (formerly "the dogfood" environment) is a self-service AI-gateway stack:
> an API-key-authenticated LLM gateway (praxis) in front of Anthropic/OpenAI plus optional
> self-hosted models, with MaaS key management and a usage-billing dashboard.
>
> This guide recreates the full stack in a **single namespace on a vanilla OpenShift 4.x
> cluster** — no OpenShift AI, no Istio, no Kuadrant, no MaaS operator required.
>
> Every manifest, env var, and RBAC rule here was extracted from a validated PriceTag
> OpenShift deployment. Environment-specific values are explicitly parameterized below.
> Where something is environment-specific (hostnames, IPs, groups), it is parameterized.
>
> This document is written to be executable by a human **or** another AI model: every step
> has exact commands and complete YAML. Do not improvise values — they're marked below.

---

## 1. What you're deploying

```
                        ┌────────────────────────── Routes (edge TLS) ──────────────────────────┐
 All AI clients ───────►│ ai-gateway-<ns>.<appsDomain> (one host; path selects API dialect) │
 Browser  ─────────────►│ dashboard-… (PriceTag)                 status-… (static status page)   │
                        └───────┬────────────────────────────────────────────┬───────────────────┘
                                ▼                                            ▼
                        ┌───────────────┐    validate key     ┌──────────────┐
                        │    praxis     │────────────────────►│   maas-api   │◄── MaaS CRDs
                        │  (Rust gateway)│   x-tenant-* ids   │  (Go, keys)  │    (subscriptions,
                        └───────┬───────┘◄────────────────────┴──────┬───────┘     model refs,
                                │  report usage (fail-open)          │             auth policies)
                                ▼                                    ▼
                        ┌───────────────────┐              ┌──────────────┐         ┌────────────┐
                        │ metering-service  │◄────────────►│  PostgreSQL  │◄────────┤ dashboard  │
                        │  (PriceTag, Go)   │  events+DB   │  (16-alpine) │  reads  │  login:    │
                        └───────────────────┘              └──────────────┘         │ key = login│
                                │                                                   └────────────┘
                                ├──► api.anthropic.com:443   (TLS SNI, pooled)
                                ├──► api.openai.com:443      (TLS SNI, pooled)
                                ├──► vLLM / self-hosted backends (optional)
```

### Components

| Component | What it is | Source repo | Language |
|---|---|---|---|
| **praxis** | The gateway. API-key auth, model allow/deny, routing, credential injection, metering, TLS pooling | [Praxis AI](https://github.com/praxis-proxy/ai) | Rust |
| **maas-api** | MaaS key server — creates/validates `sk-…` API keys, backed by Postgres + MaaS CRDs | [models-as-a-service](https://github.com/opendatahub-io/models-as-a-service) (`maas-api/`) | Go |
| **metering-service** | **PriceTag** — token-usage billing + admin dashboard. Login = paste your MaaS API key | [pricetag-metering](https://github.com/redhat-et/pricetag-metering) | Go |
| **postgresql** | Shared DB for maas-api (keys) and metering-service (usage events) | `postgres:16-alpine` | — |
| **llm-katan** | Optional benchmark backend in the dogfood/test profiles; omitted from EnMaaS | llm-katan | Python |
| **qwen-flash-proxy** | Optional: nginx TLS-terminating hop to an external vLLM route | `nginx:1-alpine` | — |

### Request flow (one public host, protocol paths)

1. The shared host path-routes Anthropic `/v1/messages` to the Messages pipeline and OpenAI `/v1/chat/completions`, `/v1/responses`, and `/v1/conversations` to the OpenAI-compatible pipeline.
2. Each pipeline validates its native client credential (`x-api-key` for Anthropic, `Authorization: Bearer` for OpenAI) against `maas-api` (`POST /internal/v1/api-keys/validate`, 300 s cache), then sets `x-tenant-*` identity headers (`identity_header_guard` strips client-supplied ones first). Anthropic SDK requests carry `anthropic-version: 2023-06-01`.
3. Both client families use `GET /v1/models`; the `anthropic-version` header selects the Anthropic envelope, while requests without it receive the OpenAI list envelope.
4. `model_access` enforces per-group allow/deny lists (groups come from the key's `X-MaaS-Group` at creation).
5. `model_to_header` promotes the body's `"model"` field to `X-Model`; protocol-specific routers select OpenAI, Qwen, GLM, or Anthropic backends.
6. `external_metering` records the request + streamed response usage to metering-service (`fail_open: true` — metering never blocks traffic).
7. `credential_injection` swaps in the real provider key (client credential stripped); `load_balancer` sends it upstream with correct `Host`/SNI.

---

## 2. Prerequisites

| Requirement | Notes |
|---|---|
| OpenShift 4.22 tested | The current CNPG manifest is SCC-compatible with the EnMaaS OpenShift 4.22 cluster. Other versions need validation. |
| `oc` CLI, cluster-admin | Use a dedicated target kubeconfig. `deploy.sh` refuses the protected production API server. |
| Storage class with RWO support | For the Postgres PVC. EnMaaS uses AWS EBS `gp3-csi`; verify with `oc get storageclass`. |
| AWS region and OIDC issuer (AWS/ROSA) | The cluster region, OIDC issuer, and IAM role must be known before deployment. |
| Private S3 bucket | Same region as the cluster, versioning enabled, all public access blocked, and server-side encryption enabled. |
| CNPG backup IAM role | Trusted only by `system:serviceaccount:enmaas:aigateway-pg`; the EnMaaS manifest uses `inheritFromIAMRole`, never static AWS keys. |
| Provider egress | praxis dials `api.anthropic.com:443` / `api.openai.com:443`; the EnMaaS Vertex deployment also needs `aiplatform.googleapis.com:443` and OAuth token egress. Verify from a pod in the target namespace. |
| Provider API keys | A real Anthropic key and (optionally) OpenAI key. These go in one Secret; praxis injects them upstream. |
| Component images | Approved component images must already exist in the target registry. The EnMaaS profile uses mirrored `practice-*` tags; `deploy.sh` does not build images. |
| Source inputs | Approved component images or pinned source revisions. The three required MaaS CRDs are vendored under `deploy/openshift/crds/`. |
| *(optional)* Self-hosted model backends | Any OpenAI- or Anthropic-dialect vLLM endpoint. If none, drop the `vllm`/`qwen-flash` bits from praxis config and model catalog. |

**Not needed** (common false alarm): OpenShift AI / RHOAI, the MaaS controller/operator,
Istio/Service Mesh, Kuadrant, Gateway API CRDs, Red Hat OpenShift Serverless. The old
legacy runbook (`docs/dogfood-runbook.md`) uses all of those — it is the **legacy
architecture**. This guide replaces it entirely. The deployment installs the vendored
CloudNativePG operator and the 3 MaaS CRDs; no other platform operators are required.

---

## 3. Per-environment parameters

Set these once; every command below references them. Values marked **⟨pick⟩** have no
default — choose per environment.

```bash
NS=ai-gateway-dogfood                  # namespace ⟨pick⟩ — keep it short, it embeds in route hosts
APPS_DOMAIN=$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')   # e.g. apps.ocp.example.com
ROUTE_DOMAIN=$(oc get ingress.config.openshift.io cluster -o jsonpath='{.spec.domain}')
GATEWAY_HOST="ai-gateway-${NS}.${ROUTE_DOMAIN}"
GATEWAY_URL="https://${GATEWAY_HOST}"
ADMIN_USERS="alice@redhat.com,bob@redhat.com"                        # PriceTag dashboard admins ⟨pick⟩
SUPERADMIN_USERS="alice@redhat.com"                                  # platform operators ⟨pick⟩
STORAGE_CLASS=$(oc get sc -o jsonpath='{.items[0].metadata.name}')   # any RWO-capable class
MAAS_SECURE=false                                                      # internal HTTP; edge Routes terminate TLS
MAAS_DEBUG_MODE=false                                                 # enable only for controlled local/test setup
ANTHROPIC_API_KEY=⟨real Anthropic API key⟩
OPENAI_API_KEY=⟨real OpenAI API key, or empty⟩
LITELLM_API_KEY=⟨real LiteLLM key, or empty⟩
CB_LITELLM_API_KEY=⟨real curvebender/LiteLLM key, or empty⟩
QWEN_ENDPOINT=⟨self-hosted Qwen endpoint hostname⟩
CB_GLM_ENDPOINT=⟨GLM/LiteLLM endpoint hostname⟩
# IBM COS credentials; required for dogfood/test, omitted for enmaas.
COS_ACCESS_KEY_ID=⟨COS access key⟩
COS_SECRET_ACCESS_KEY=⟨COS secret key⟩
COS_BUCKET=⟨environment backup bucket⟩
COS_ENDPOINT=⟨environment COS endpoint⟩
COS_REGION=⟨object-store signing region⟩
# AWS/ROSA workload identity; required for enmaas, omitted for dogfood/test.
AWS_ROLE_ARN=⟨CNPG backup role ARN⟩

# Generated — never reuse a value from another environment or from git:
PG_PASSWORD=$(openssl rand -hex 16)
SESSION_SECRET=$(openssl rand -hex 32)     # PriceTag session-cookie signing key
```

What the dashboard does with `ADMIN_USERS`: those logins get the admin view (all users,
key management, impersonation). Everyone else sees only their own usage.

`MAAS_SECURE` controls TLS on the in-cluster MaaS API listener. The current Praxis
configuration calls `http://maas-api:8080`, so leave it `false` unless you also provision
and mount a CA-trusted certificate and update every internal client URL. OpenShift Routes
still terminate external TLS at the edge.

### 3.1 AWS/ROSA prerequisites

The AWS resources are not created by `deploy.sh`; provision and verify them first:

For an AWS/ROSA target, use the idempotent provisioner. It verifies the current
AWS identity and OIDC provider, creates or reconciles the private/versioned/
encrypted bucket, and creates or reconciles the least-privilege CNPG role:

```bash
export AWS_REGION=us-west-2
export S3_BUCKET=pricetag-enmaas-cnpg-<account-id>-usw2
export OIDC_PROVIDER_HOST=oidc.op1.openshiftapps.com/<cluster-oidc-id>
export S3_RETENTION_DAYS=30
./deploy/openshift/provision-aws-backup-target.sh
```

The role provisioner requires IAM permissions and must be run by an AWS
administrator. The output `Role` value becomes `AWS_ROLE_ARN` for `deploy.sh`.
It is safe to rerun; it does not delete bucket data or rotate application
credentials.

```bash
AWS_REGION=us-west-2
BUCKET=pricetag-enmaas-cnpg-<account-id>-usw2

aws sts get-caller-identity
aws s3api head-bucket --bucket "$BUCKET" --region "$AWS_REGION"
aws s3api get-bucket-location --bucket "$BUCKET"
aws s3api get-bucket-versioning --bucket "$BUCKET"
aws s3api get-bucket-encryption --bucket "$BUCKET"
aws s3api get-public-access-block --bucket "$BUCKET"
```

The bucket must be in the OpenShift cluster's AWS region, have versioning enabled,
server-side encryption enabled, block all public access, and expire current and
noncurrent objects after the configured retention period. Set retention according
to the recovery requirement; `30` days is the EnMaaS practice default. Do not put
AWS access keys in a Kubernetes Secret for EnMaaS.

This is an automatic S3 lifecycle policy, not a credential or subscription
renewal. It does not stop the database or future backups. It removes old base
backup/WAL objects and therefore limits how far back a restore can go. Increase
`S3_RETENTION_DAYS` to `90` or `180` for an environment that needs a longer
historical recovery window.

Create a dedicated IAM role for the CNPG instance ServiceAccount. Its trust policy
must restrict both the cluster OIDC provider and this subject:

```text
system:serviceaccount:enmaas:aigateway-pg
```

For this ROSA/OpenShift cluster, the projected token audience is `openshift`
(not the EKS default `sts.amazonaws.com`). The trust condition must therefore
use `ForAnyValue:StringEquals` for `<oidc-provider-host>:aud = openshift`
because OpenShift emits `aud` as an array, and `StringEquals` for
`<oidc-provider-host>:sub = system:serviceaccount:enmaas:aigateway-pg`.

The role needs only `GetBucketLocation`, `ListBucket`, and multipart/object read/write/delete
permissions on the dedicated backup bucket. Set its ARN as `AWS_ROLE_ARN`; the EnMaaS
CNPG manifest uses `s3Credentials.inheritFromIAMRole: true`.

The cluster must expose an AWS OIDC issuer, have the AWS EBS CSI driver, and provide an
RWO storage class. Verify the target before deploying:

```bash
oc whoami --show-server
oc get storageclass gp3-csi
oc get --raw /.well-known/openid-configuration
```

### 3.2 Guarded deploy inputs

`deploy.sh` requires a dedicated target kubeconfig and refuses the production API server.
It also requires the target server, profile, namespace, storage class, object-store values,
provider keys, model endpoint hostnames, admin lists, and `CONFIRM_DEPLOYMENT=true`. The
EnMaaS profile additionally requires `VERTEX_PROJECT` and `VERTEX_IMAGE_TAG`; on first
install or intentional key rotation it requires `VERTEX_SA_KEY_FILE`.
The EnMaaS invocation is:

```bash
export PROFILE=enmaas
export NAMESPACE=enmaas
export STORAGE_CLASS=gp3-csi
export PRICETAG_KUBECONFIG=/path/to/enmaas-kubeconfig
export EXPECTED_OC_SERVER=https://<enmaas-api>:443
export PROTECTED_OC_SERVER=https://<production-api>:<port>
export AWS_ROLE_ARN=arn:aws:iam::<account-id>:role/pricetag-enmaas-cnpg-backup
export COS_BUCKET=pricetag-enmaas-cnpg-<account-id>-usw2
export COS_ENDPOINT=https://s3.us-west-2.amazonaws.com
export COS_REGION=us-west-2
export VERTEX_PROJECT=<gcp-project-id>
export VERTEX_IMAGE_TAG=practice-<immutable-feature-image-sha>
# Required only to create vertex-sa-key on first install or rotate it:
export VERTEX_SA_KEY_FILE=/secure/path/to/service-account.json
# Set only when rotating the Vertex key; ROTATE_SECRETS=true rotates all managed Secrets.
export ROTATE_VERTEX_SA_KEY=false
export CONFIRM_DEPLOYMENT=true

./deploy/openshift/deploy.sh
```

Run this from the repository containing the mirrored EnMaaS image tags. The script
creates the namespace, CRDs, CNPG operator, database, applications, and Routes in that
target only. It does not build images, create the AWS bucket, create the IAM role, copy
production data, or migrate production secrets automatically. MaaS governance CRs are
intentionally not applied because this profile does not deploy the MaaS controller.
The EnMaaS overlay uses the fork-built MaaS API image with
`MAAS_SUBSCRIPTION_MODE=standalone`; dogfood and test retain enforced subscription mode.

### 3.3 EnMaaS Vertex routing

The EnMaaS overlay adds Vertex as another supplier behind the existing Praxis
`unified` listener and canonical `ai-gateway` Route at `/v1/messages`. It uses
the existing Praxis Deployment and API endpoint: clients send the stable model
ID `claude-sonnet-4-5`; Praxis maps it to the Vertex route and internal target
model. Existing Claude, Qwen, and GLM model routes continue to use their
current suppliers. Other profiles do not enable the Vertex route or mount its
service-account Secret.

Before deploying EnMaaS Vertex:

1. Set `PRAXIS_SOURCE_SHA` to the full SHA of a pushed
   `redhat-et/praxis-ai` commit containing the GCP key-file credential filter,
   Vertex dialect filter, model-to-provider mapping, and `token_count`
   StreamBuffer fix. EnMaaS deployment builds that ET commit in OpenShift with
   `PRAXIS_AI_FEATURES=full,gcp-adc-filter` by default and deploys its
   commit-derived `practice-*` tag. Record the source SHA and the image digest
   printed by `build-praxis-et.sh`. To use an already-built/mirrored image,
   set `BUILD_PRAXIS_IMAGE=false` and provide its `VERTEX_IMAGE_TAG`; ensure it
   came from the same pushed source commit and feature set.
2. Set `VERTEX_PROJECT` to the GCP project used by the service account.
3. For the initial install, set `VERTEX_SA_KEY_FILE` to the service-account
   JSON file. The deploy script creates `vertex-sa-key` from that file and
   mounts it into the existing Praxis pods. The Secret is preserved on later
   runs. To rotate only this key, set `ROTATE_VERTEX_SA_KEY=true` and provide
   the replacement file. `ROTATE_SECRETS=true` still intentionally rotates all
   managed Secrets. Key contents are never placed in a manifest.

This is the initial key-file credential path; GCP Workload Identity Federation
is not included. Requests use the existing Anthropic Messages endpoint and are
authenticated by PriceTag API keys, pass through the EnMaaS model-access policy,
and meter through the existing gateway path. Clients use the stable public ID
`claude-sonnet-4-5`; Praxis maps it to the internal `vertex/claude-sonnet-4-5`
target and restores the public ID in responses and metering.

---

## 4. Install

Run steps in order. Each is idempotent (`apply`) unless noted.

### 4.1 Namespace + image streams

```bash
oc create namespace "$NS" --dry-run=client -o yaml | oc apply -f -
oc project "$NS"
```

### 4.2 Secrets

```bash
# Provider credentials (consumed by praxis, injected upstream)
oc create secret generic provider-credentials -n "$NS" \
  --from-literal=ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  --from-literal=OPENAI_API_KEY="$OPENAI_API_KEY" \
  --from-literal=LITELLM_API_KEY="$LITELLM_API_KEY" \
  --from-literal=CB_LITELLM_API_KEY="$CB_LITELLM_API_KEY" \
  --dry-run=client -o yaml | oc apply -f -

# CNPG application credentials. The cluster uses the aigateway-pg-rw service.
oc create secret generic aigateway-db-app -n "$NS" \
  --from-literal=username=aigateway \
  --from-literal=password="$PG_PASSWORD" \
  --dry-run=client -o yaml | oc apply -f -

oc create secret generic postgresql-credentials -n "$NS" \
  --from-literal=POSTGRES_USER=aigateway \
  --from-literal=POSTGRES_DB=aigateway \
  --from-literal=POSTGRES_PASSWORD="$PG_PASSWORD" \
  --from-literal=MAAS_DB_URL="postgresql://aigateway:${PG_PASSWORD}@aigateway-pg-rw:5432/aigateway?sslmode=disable" \
  --from-literal=METERING_DB_URL="postgresql://aigateway:${PG_PASSWORD}@aigateway-pg-rw:5432/aigateway?sslmode=disable" \
  --dry-run=client -o yaml | oc apply -f -

# maas-api reads its DSN from THIS secret via the K8s API (not env vars) —
# exact name and key are hardcoded in its config loader:
oc create secret generic maas-db-config -n "$NS" \
  --from-literal=DB_CONNECTION_URL="postgresql://aigateway:${PG_PASSWORD}@aigateway-pg-rw:5432/aigateway?sslmode=disable" \
  --dry-run=client -o yaml | oc apply -f -

# dogfood/test only; EnMaaS uses AWS workload identity instead.
oc create secret generic cnpg-backup-cos -n "$NS" \
  --from-literal=ACCESS_KEY_ID="$COS_ACCESS_KEY_ID" \
  --from-literal=SECRET_ACCESS_KEY="$COS_SECRET_ACCESS_KEY" \
  --dry-run=client -o yaml | oc apply -f -
```

> Create two databases (e.g. `maas` and `metering`) if you want app-level separation —
> the live environment shares one. Update both DSNs accordingly.

### 4.3 CloudNativePG PostgreSQL

The supported deployment uses the pinned CloudNativePG operator and a three-
instance cluster. Do not deploy the retired single-pod PostgreSQL manifests.

The vendored CNPG operator manifest includes the required OpenShift SCC
compatibility adjustment: it does not pin the controller UID/GID. Do not
replace it with the raw upstream manifest.

```bash
oc apply -f deploy/openshift/database/cnpg/cnpg-operator-1.30.0.yaml
oc -n cnpg-system wait deploy/cnpg-controller-manager \
  --for=condition=Available --timeout=5m

# Set the environment-specific object-store endpoint, bucket, storage class,
# and generated application secret before applying these manifests. EnMaaS
# uses 10-cluster-enmaas.yaml and AWS_ROLE_ARN instead of static credentials.
oc apply -f deploy/openshift/database/cnpg/10-cluster.yaml
oc apply -f deploy/openshift/database/cnpg/20-scheduled-backup.yaml
oc -n "$NS" wait cluster/aigateway-pg --for=condition=Ready --timeout=10m
```

The production profile uses three instances, 10Gi RWO volumes, the selected
environment storage class, and SigV4 backups to IBM COS. The endpoint,
destination bucket, credentials, and region are environment parameters; none
are committed as secrets.

The restore, parity, heartbeat, and read-replica procedures live under
`deploy/openshift/database/` and must be run only with the operational gates
documented in `docs/db-backup.md`.

### 4.4 MaaS CRDs (3 — installed manually, no operator)

```bash
oc apply -f deploy/openshift/crds/maas.opendatahub.io_maasauthpolicies.yaml
oc apply -f deploy/openshift/crds/maas.opendatahub.io_maasmodelrefs.yaml
oc apply -f deploy/openshift/crds/maas.opendatahub.io_maassubscriptions.yaml
```

Only these three CRDs are needed. (`externalmodels.maas.opendatahub.io` is **not**
installed in the live env — `MaaSModelRef` records reference model names that maas-api
never resolves, so its absence is fine.)

### 4.5 maas-api (RBAC + SA + build + deploy)

maas-api reads the `maas-db-config` secret, namespaces, and the MaaS CRs through the
K8s API, so it needs a dedicated ServiceAccount with a **ClusterRole** (namespaces are
cluster-scoped reads):

The ServiceAccount is namespaced as `maas-api`; the cluster-scoped role is named
`pricetag-maas-api` to avoid collisions with another MaaS installation. During
the migration from the old generic role name, `deploy.sh` removes the old
profile binding when it points at `maas-api`. It does not delete an unreferenced
old ClusterRole automatically; inspect ownership before cleaning one up on a
shared cluster.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata: { name: maas-api, namespace: ai-gateway-dogfood }   # ← $NS
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: maas-api }
rules:
- { apiGroups: [""], resources: [secrets], resourceNames: [maas-db-config], verbs: [get] }   # in practice: scope per-namespace via binding below
- { apiGroups: [""], resources: [namespaces], verbs: [get, list, watch, create] }
- { apiGroups: [""], resources: [serviceaccounts], verbs: [get, list, watch, create, delete] }
- { apiGroups: [""], resources: [serviceaccounts/token], verbs: [create] }
- { apiGroups: [authentication.k8s.io], resources: [tokenreviews], verbs: [create] }
- { apiGroups: [authorization.k8s.io], resources: [subjectaccessreviews], verbs: [create] }
- { apiGroups: [maas.opendatahub.io], resources: [maasauthpolicies, maasmodelrefs, maassubscriptions], verbs: [get, list, watch] }
- { apiGroups: [gateway.networking.k8s.io], resources: [httproutes], verbs: [get, list, watch] }   # harmless if Gateway API absent; drop otherwise
- { apiGroups: [""], resources: [pods, services, endpoints], verbs: [get, list, watch] }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: maas-api }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: maas-api }
subjects: [ { kind: ServiceAccount, name: maas-api, namespace: ai-gateway-dogfood } ]  # ← $NS
```

> The live env scopes `secrets` by resourceName only at cluster level. If your security
> posture forbids cluster-wide secret get even by name, note this as a known deviation —
> maas-api's config loader requires this exact read.

Build and deploy:

```bash
oc apply -n "$NS" -f - <<EOF
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata: { name: maas-api }
spec:
  runPolicy: Serial
  source: { type: Binary, binary: {} }
  strategy:
    dockerStrategy:
      dockerfilePath: Dockerfile
  output: { to: { kind: ImageStreamTag, name: 'maas-api:latest' } }
  sourceSecret: {}
EOF
# NOTE: build context = the models-as-a-service/maas-api directory (it is its own Go module)
oc start-build bc/maas-api -n "$NS" --from-dir=/path/to/models-as-a-service/maas-api --wait
```

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: maas-api }
spec:
  replicas: 1
  selector: { matchLabels: { app: maas-api } }
  template:
    metadata: { labels: { app: maas-api } }
    spec:
      serviceAccountName: maas-api
      containers:
      - name: maas-api
        image: image-registry.openshift-image-registry.svc:5000/ai-gateway-dogfood/maas-api:latest   # ← $NS
        ports:
        - { containerPort: 8080, name: http }
        - { containerPort: 9090, name: metrics }
        env:
        - name: NAMESPACE
          valueFrom: { fieldRef: { fieldPath: metadata.namespace } }
        - { name: SECURE,                      value: "false" }   # ⚠ see Security notes
        - name: MAAS_SUBSCRIPTION_NAMESPACE
          valueFrom: { fieldRef: { fieldPath: metadata.namespace } }
        - { name: METRICS_PORT,                value: "9090" }
        - { name: DEBUG_MODE,                  value: "true" }    # ⚠ see Security notes
        - { name: API_KEY_MAX_EXPIRATION_DAYS, value: "365" }
        readinessProbe: { httpGet: { path: /health, port: 8080 } }
        livenessProbe:  { httpGet: { path: /health, port: 8080 } }
---
apiVersion: v1
kind: Service
metadata: { name: maas-api }
spec:
  ports:
  - { name: http,    port: 8080 }
  - { name: metrics, port: 9090 }
  selector: { app: maas-api }
```

`SECURE=false` + `DEBUG_MODE=true` is what lets key creation accept trusted
`X-MaaS-Username`/`X-MaaS-Group` headers (see 4.9). This is the dogfood trade-off —
documented under Security.

### 4.6 MaaS model refs + subscription (CRs)

These grant key-holders access. Model names here are what maas-api meters/permits;
routing itself is praxis's job.

```yaml
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata: { name: claude-sonnet, namespace: ai-gateway-dogfood }
spec:
  endpointOverride: https://api.anthropic.com
  modelRef: { kind: ExternalModel, name: claude-sonnet-4 }
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata: { name: gpt-4o, namespace: ai-gateway-dogfood }
spec:
  endpointOverride: https://api.openai.com
  modelRef: { kind: ExternalModel, name: gpt-4o }
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata: { name: dogfood-team, namespace: ai-gateway-dogfood }
spec:
  priority: 10
  owner:
    users: [admin@your-org.com]                  # ⟨pick⟩ at least yourself
    groups:                                       # ⟨pick⟩ IdM/LDAP groups, or invent names and
      - dogfood-testing                           #   pass them explicitly at key creation
  modelRefs:
  - name: claude-sonnet
    namespace: ai-gateway-dogfood
    tokenRateLimits: [ { limit: 1000000000, window: 24h } ]
  - name: gpt-4o
    namespace: ai-gateway-dogfood
    tokenRateLimits: [ { limit: 1000000000, window: 24h } ]
```

> ⚠ In the **current** wiring, praxis does not re-check subscriptions per-request —
> auth is key-validity + `model_access` group rules in praxis config. The CRs are the
> source of truth for key creation limits/tenant checks in maas-api and for the
> dashboard's model list. Keep both sides consistent when adding models.

### 4.7 praxis (gateway) — config, build, deploy, routes

**Config** — the full live `praxis.yaml` is long; this is the complete template with
the three standard chains. Replace `⟨…⟩` items. The `vllm` cluster endpoint `10.240.0.10:8000` in
the live env is a node-internal address — substitute your own self-hosted backend or
delete the `vllm`/`qwen-flash` routes+clusters and their catalog entries.

```yaml
apiVersion: v1
kind: ConfigMap
metadata: { name: praxis-config }
data:
  praxis.yaml: |
    admin:
      address: "0.0.0.0:9901"
    insecure_options:
      allow_public_admin: true        # ⚠ live env value — see Security notes
    listeners:
      - { name: anthropic, address: "0.0.0.0:8080", filter_chains: [anthropic] }
      - { name: openai,    address: "0.0.0.0:8081", filter_chains: [openai] }
      - { name: unified,   address: "0.0.0.0:8084", filter_chains: [unified] }
    filter_chains:
      # ---- anthropic-only chain ----
      - name: anthropic
        filters:
          - { filter: api_key_auth, validate_url: "http://maas-api:8080/internal/v1/api-keys/validate", token_header: "x-api-key", cache_ttl_seconds: 300, timeout_seconds: 5 }
          - filter: model_access
            mode: denylist
            models: ["claude-fable-*"]
            overrides:
              - { groups: ["⟨trusted-group⟩"], mode: allowlist, models: ["*"] }
            group_metadata_key: "x-tenant-group"
            max_body_bytes: 33554432
          - { filter: identity_header_guard, prefix: "x-tenant-" }
          - { filter: router, routes: [ { path_prefix: "/", cluster: anthropic } ] }
          - { filter: external_metering, metering_url: "http://metering-service:8080", timeout_seconds: 5, feature_key: "inference-tokens", source: "praxis-ai", fail_open: true, identity_header_prefix: "x-tenant-", default_model: "unknown" }
          - { filter: token_count, provider: anthropic }
          - { filter: token_usage_headers }
          - filter: credential_injection
            clusters:
              - { name: anthropic, header: x-api-key, env_var: ANTHROPIC_API_KEY, strip_client_credential: true }
          - filter: headers
            request_set:
              - { name: "Host", value: "api.anthropic.com" }
              - { name: "anthropic-version", value: "2023-06-01" }
          - filter: load_balancer
            clusters:
              - name: anthropic
                tls: { sni: "api.anthropic.com" }
                idle_timeout_ms: 45000     # MUST stay below provider keepalive kill (~60s) — see gotchas
                endpoints: ["api.anthropic.com:443"]
      # ---- openai-only chain: identical, with token_header "authorization",
      #      credential env OPENAI_API_KEY, header_prefix "Bearer ", Host api.openai.com,
      #      provider openai, cluster openai endpoints ["api.openai.com:443"] ----
      - name: openai
        filters:
          - { filter: api_key_auth, validate_url: "http://maas-api:8080/internal/v1/api-keys/validate", token_header: "authorization", cache_ttl_seconds: 300, timeout_seconds: 5 }
          - { filter: model_access, mode: denylist, models: ["claude-fable-*"], group_metadata_key: "x-tenant-group", max_body_bytes: 33554432 }
          - { filter: identity_header_guard, prefix: "x-tenant-" }
          - { filter: router, routes: [ { path_prefix: "/", cluster: openai } ] }
          - { filter: external_metering, metering_url: "http://metering-service:8080", timeout_seconds: 5, feature_key: "inference-tokens", source: "praxis-ai", fail_open: true, identity_header_prefix: "x-tenant-", default_model: "unknown" }
          - { filter: token_count, provider: openai }
          - { filter: token_usage_headers }
          - filter: credential_injection
            clusters:
              - { name: openai, header: Authorization, env_var: OPENAI_API_KEY, header_prefix: "Bearer ", strip_client_credential: true }
          - { filter: headers, request_set: [ { name: "Host", value: "api.openai.com" } ] }
          - filter: load_balancer
            clusters:
              - name: openai
                tls: { sni: "api.openai.com" }
                idle_timeout_ms: 45000
                endpoints: ["api.openai.com:443"]
      # ---- unified: Anthropic-dialect, one URL, model-name routing ----
      - name: unified
        filters:
          - { filter: api_key_auth, validate_url: "http://maas-api:8080/internal/v1/api-keys/validate", token_header: "x-api-key", cache_ttl_seconds: 300, timeout_seconds: 5 }
          - filter: model_catalog               # answers GET /v1/models from config
            format: anthropic
            path: /v1/models
            models:                             # ⟨edit⟩ — what client /model pickers see
              - { id: Qwen3.8-27B-FP8,             display_name: "Qwen3.8-27B-FP8 (self-hosted, $0)", owned_by: vllm }
              - { id: claude-opus-4-8,             display_name: "Claude Opus 4.8" }
              - { id: claude-sonnet-5,             display_name: "Claude Sonnet 5" }
              - { id: claude-haiku-4-5-20251001,   display_name: "Claude Haiku 4.5" }
          - { filter: model_access, mode: denylist, models: ["claude-fable-*"], group_metadata_key: "x-tenant-group", max_body_bytes: 33554432 }
          - { filter: identity_header_guard, prefix: "x-tenant-" }
          - { filter: model_to_header, header: X-Model }      # promote body.model → header for routing
          - filter: router
            routes:                             # ⟨edit⟩ self-hosted names first, provider default last
              - { path_prefix: "/", headers: { x-model: "Qwen3.8-27B-FP8" }, cluster: vllm }
              - { path_prefix: "/", cluster: anthropic }
          - { filter: external_metering, metering_url: "http://metering-service:8080", timeout_seconds: 5, feature_key: "inference-tokens", source: "praxis-ai", fail_open: true, identity_header_prefix: "x-tenant-", default_model: "unknown" }
          - { filter: token_count, provider: anthropic }      # both backends speak Anthropic usage
          - { filter: token_usage_headers }
          - filter: credential_injection
            clusters:                           # only anthropic needs an upstream key; vllm matches nothing → no injection
              - { name: anthropic, header: x-api-key, env_var: ANTHROPIC_API_KEY, strip_client_credential: true }
          - { filter: headers, request_set: [ { name: "Host", value: "api.anthropic.com" }, { name: "anthropic-version", value: "2023-06-01" } ] }  # ⚠ see gotcha #4
          - filter: load_balancer
            clusters:
              - name: anthropic
                tls: { sni: "api.anthropic.com" }
                idle_timeout_ms: 45000
                endpoints: ["api.anthropic.com:443"]
              - { name: vllm, idle_timeout_ms: 45000, endpoints: ["⟨your-vllm-host:port⟩"] }   # or delete route+cluster
```

> Fetch the authoritative live version instead of retyping:
> `oc get cm praxis-config -n ai-gateway-dogfood -o jsonpath='{.data.praxis\.yaml}' > praxis.yaml`
> then edit environment-specific bits. The YAML above documents every filter; the live CM
> is the canonical instance.

**Build & deploy:**

```bash
# BuildConfig identical in shape to maas-api's, named praxis-ai.
# Build context = praxis-ai repo root (Rust workspace, Containerfile; ~10 min cold).
oc start-build bc/praxis-ai -n "$NS" --from-dir=/path/to/praxis-ai --wait
```

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: praxis }
spec:
  replicas: 1
  selector: { matchLabels: { app: praxis } }
  template:
    metadata: { labels: { app: praxis } }
    spec:
      containers:
      - name: praxis
        image: image-registry.openshift-image-registry.svc:5000/ai-gateway-dogfood/praxis-ai:latest   # ← $NS
        args: ["-c", "/etc/praxis/praxis.yaml"]
        ports:
        - { containerPort: 8080, name: anthropic }
        - { containerPort: 8081, name: openai }
        - { containerPort: 8084, name: unified }
        - { containerPort: 9901, name: admin }
        envFrom:
        - secretRef: { name: provider-credentials }
        volumeMounts:
        - { name: config, mountPath: /etc/praxis }
        resources:
          requests: { cpu: 100m, memory: 128Mi }
          limits:   { memory: 512Mi }
      volumes:
      - name: config
        configMap: { name: praxis-config }
---
apiVersion: v1
kind: Service
metadata: { name: praxis }
spec:
  ports:
  - { name: anthropic, port: 8080, targetPort: anthropic }
  - { name: openai,    port: 8081, targetPort: openai }
  - { name: unified,   port: 8084, targetPort: unified }
  - { name: admin,     port: 9901, targetPort: admin }
  selector: { app: praxis }
```

> **Config reload**: the praxis pod reads the CM at start. After editing `praxis-config`,
> run `oc rollout restart deploy/praxis -n "$NS"`.

### 4.8 metering-service (PriceTag) + RBAC + route

The dashboard reads the `praxis-config` CM (for its routing view) through the K8s API —
hence the one-rule Role scoped to that single object:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: metering-service }
rules:
- { apiGroups: [""], resources: [configmaps], resourceNames: [praxis-config], verbs: [get] }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: metering-service }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: metering-service }
subjects: [ { kind: ServiceAccount, name: default } ]
```

```bash
# Build context = the pricetag-metering repository root (Dockerfile at root).
oc start-build bc/metering-service -n "$NS" --from-dir=/path/to/pricetag-metering --wait
```

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: metering-service }
spec:
  replicas: 1
  selector: { matchLabels: { app: metering-service } }
  template:
    metadata: { labels: { app: metering-service } }
    spec:
      containers:
      - name: metering-service
        image: image-registry.openshift-image-registry.svc:5000/ai-gateway-dogfood/metering-service:latest   # ← $NS
        ports: [ { containerPort: 8080 } ]
        env:
        - name: DATABASE_URL
          valueFrom: { secretKeyRef: { name: postgresql-credentials, key: METERING_DB_URL } }
        - name: K8S_NAMESPACE
          valueFrom: { fieldRef: { fieldPath: metadata.namespace } }
        - { name: ADMIN_USERS,                  value: "alice@redhat.com,bob@redhat.com" }  # ← $ADMIN_USERS
        - { name: SESSION_SECRET,               value: "⟨SESSION_SECRET⟩" }                 # ⚠ put in a Secret, not inline (see Security)
        - { name: ALLOW_UNAUTHENTICATED_ADMIN,  value: "false" }
        - { name: MONTHLY_TOKEN_QUOTA,          value: "10000000000" }
        - { name: PIPELINE_CONFIGMAP,           value: "praxis-config" }
        - { name: PIPELINE_CONFIGMAP_KEY,       value: "praxis.yaml" }
        # Defaults that work in-cluster as-is: MAAS_VALIDATE_URL=http://maas-api:8080/…,
        # MAAS_API_URL derived from it, PORT=8080.
        livenessProbe:  { httpGet: { path: /health, port: 8080 }, initialDelaySeconds: 10 }
        readinessProbe: { httpGet: { path: /ready,  port: 8080 } }
---
apiVersion: v1
kind: Service
metadata: { name: metering-service }
spec:
  ports: [ { port: 8080 } ]
  selector: { app: metering-service }
```

**Login model** (important for the peer): the PriceTag login page takes **the user's MaaS
API key**, POSTs it to `MAAS_VALIDATE_URL`, and on `valid:true` issues a signed session
cookie (`SESSION_SECRET`) carrying the key's username+groups. No OpenShift OAuth, no
oauth-proxy container. `ADMIN_USERS` members additionally get the admin view.

### 4.9 Routes

```yaml
# One public inference hostname. OpenShift path routes dispatch each API path
# to its protocol-specific Praxis listener; clients see one base URL.
apiVersion: route.openshift.io/v1
kind: Route
metadata: { name: ai-gateway }
spec:
  host: ${GATEWAY_HOST}
  path: /v1/messages
  to: { kind: Service, name: praxis }
  port: { targetPort: unified }
  tls: { termination: edge }
---
apiVersion: route.openshift.io/v1
kind: Route
metadata: { name: ai-gateway-chat-completions }
spec:
  host: ${GATEWAY_HOST}
  path: /v1/chat/completions
  to: { kind: Service, name: praxis }
  port: { targetPort: openai }
  tls: { termination: edge }
---
apiVersion: route.openshift.io/v1
kind: Route
metadata: { name: ai-gateway-models }
spec:
  host: ${GATEWAY_HOST}
  path: /v1/models
  to: { kind: Service, name: praxis }
  port: { targetPort: unified }
  tls: { termination: edge }
---
apiVersion: route.openshift.io/v1
kind: Route
metadata: { name: ai-gateway-responses }
spec:
  host: ${GATEWAY_HOST}
  path: /v1/responses
  to: { kind: Service, name: praxis }
  port: { targetPort: openai }
  tls: { termination: edge }
---
apiVersion: route.openshift.io/v1
kind: Route
metadata: { name: ai-gateway-conversations }
spec:
  host: ${GATEWAY_HOST}
  path: /v1/conversations
  to: { kind: Service, name: praxis }
  port: { targetPort: openai }
  tls: { termination: edge }
---
apiVersion: route.openshift.io/v1
kind: Route
metadata: { name: dashboard }
spec: { to: { kind: Service, name: metering-service }, port: { targetPort: 8080 }, tls: { termination: edge } }
```

### 4.10 Optional components

- **llm-katan** (benchmark echo backend): build from llm-katan repo root (`Containerfile`,
  Python). Deploy `llm-katan` Deployment+Service on port 8000 with args like
  `--model=benchmark-echo --backend=echo --providers=openai,anthropic --port=8000
  --ttft-ms=800 --itl-ms=15 --error-rate=0 --max-concurrent=100 --disable-dashboard`,
  then add the benchmark listener, filter chain, Praxis ports, and Route from the
  dogfood/test profile. EnMaaS removes those resources by default.
- **qwen-flash-proxy / vllm**: whatever backend you self-host. If it's reachable by
  hostname over the network, point the praxis `load_balancer` cluster at it directly —
  the nginx hop in the live env exists only because that vLLM is on a different cluster
  behind TLS re-termination.

### 4.11 Create API keys (per user)

With `DEBUG_MODE=true`/`SECURE=false`, maas-api trusts these headers — **cluster-internal
only**; the endpoint is not exposed by any Route:

```bash
oc port-forward svc/maas-api -n "$NS" 18080:8080 &

curl -s -X POST http://localhost:18080/v1/api-keys \
  -H "X-MaaS-Username: $(oc whoami)" \
  -H 'X-MaaS-Group: ["dogfood-testing"]' \
  -H 'Content-Type: application/json' \
  -d '{"name": "first-key", "description": "dogfood"}'
# → returns {"key": "sk-…"} — show to the user ONCE; store only the hash.
kill %1
```

The group(s) you pass become the key's `x-tenant-group` values, which drive
`model_access` overrides and the dashboard's per-user view. Admins can also create keys
from the PriceTag dashboard (it proxies to `MAAS_API_URL`).

---

## 5. Verification checklist

```bash
# 1. All pods up
oc get pods,deploy,sts,routes -n "$NS"

# 2. Key validation end-to-end (maas-api ↔ postgres ↔ CRDs)
oc exec -n "$NS" deploy/maas-api -- wget -qO- --header="Content-Type: application/json" \
  --post-data='{"key":"sk-<from-4.11>"}' http://localhost:8080/internal/v1/api-keys/validate
# expect: {"valid":true,"username":"…","groups":["dogfood-testing",…]}

# 3. Gateway auth rejects garbage key
KEY=sk-<from-4.11>
curl -sk -o /dev/null -w '%{http_code}\n' \
  "$GATEWAY_URL/v1/messages" \
  -H "x-api-key: sk-bogus" -H 'content-type: application/json' \
  -d '{"model":"claude-haiku-4-5-20251001","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}'
# expect: 401

# 4. Model catalog served (proves praxis config loaded)
curl -sk "$GATEWAY_URL/v1/models" -H "x-api-key: $KEY" | head -c 300

# 5. Real completion through the gateway → Anthropic
curl -sk "$GATEWAY_URL/v1/messages" \
  -H "x-api-key: $KEY" -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' \
  -d '{"model":"claude-haiku-4-5-20251001","max_tokens":16,"messages":[{"role":"user","content":"say OK"}]}'

# 6. Usage landed in PriceTag DB
oc exec -n "$NS" deploy/metering-service -- wget -qO- http://localhost:8080/ready
oc exec -n "$NS" statefulset/postgresql -- psql -U postgres -c \
  'select model, count(*) from usage_events group by model;'   # table name per current schema

# 7. Dashboard login
open "https://dashboard-${NS}.${APPS_DOMAIN}/dashboard"   # paste the key from step 4.11
```

Point Claude Code at it:

```bash
export ANTHROPIC_BASE_URL="$GATEWAY_URL"
export ANTHROPIC_API_KEY="sk-<key>"
claude
```

---

## 6. Day-2 operations

| Task | How |
|---|---|
| Add a model | praxis `model_catalog` + `router` (+ `load_balancer` cluster if new backend) → `oc rollout restart deploy/praxis`. Add a `MaaSModelRef` + subscription entry for key-side gating. |
| Add a user group | Key creation header `X-MaaS-Group`, plus `model_access.overrides` if it needs non-default access. |
| Edit routing/pricing live | The dashboard's routing tab reads `praxis-config` (read-only via the scoped Role). To write it, edit the CM + rollout restart. |
| Rotate provider key | Update `provider-credentials` → `oc rollout restart deploy/praxis`. |
| Rotate session keys | New `SESSION_SECRET` → restart metering-service (logs everyone out). |
| Upgrades per component | `oc start-build bc/<name> --from-dir <repo> --wait && oc rollout restart deploy/<name>` (for `:latest` tags; maas-api pins digests — update its image ref after build). |

## 7. Gotchas (all learned the hard way on the live env)

1. **`idle_timeout_ms: 45000` is load-bearing.** Provider keepalive kills pooled
   connections at ~60 s; evicting at 45 s prevents hung requests until route timeout.
   Do not raise it above the provider's keepalive window.
2. **`Host` header must match SNI for Anthropic** (`Host: api.anthropic.com` set
   explicitly). vLLM ignores Host, which is why the unified chain can set it
   unconditionally — but a future Host-validating backend on that listener breaks.
3. **praxis config is start-time only** — CM edits without rollout are silently inert.
4. **x-api-key vs Authorization**: Anthropic-dialect chains validate `x-api-key`, the
   OpenAI chain `authorization: Bearer`. Clients on the wrong header get 401 even with a
   valid key. The `/v1/messages` path uses Anthropic auth (`x-api-key`); Chat Completions and Responses use Bearer auth.
5. **praxis strips inbound `x-tenant-*`** (`identity_header_guard`) — never rely on
   clients setting identity headers.
6. **Metering is fail-open** — dashboard gaps ≠ outage. Cross-check `external_metering`
   filter errors in praxis logs before trusting numbers.
7. **maas-api needs the `maas-db-config` secret before first start** — it fails fast at
   boot with a clear "ensure the secret exists" error if missing.
8. **praxis key-validation cache is 300 s** — a revoked key may still work up to 5 min.
9. **Docker builds**: praxis-ai is a Rust workspace — cold builds take ~10 min; give the
   builder pod room (default 1 CPU ok, just slow).
10. **Don't apply the legacy runbook** (`docs/dogfood-runbook.md`) — its Istio
    EnvoyFilter/Kuadrant/controller steps belong to the retired architecture.

## 8. Security notes for a production-grade deployment

The live dogfood optimizes for access, not hardening. A new environment should start
better:

- **`SESSION_SECRET` is currently a plaintext env value in the Deployment** (in the live
  env this is a leaked credential — rotate it there). Put it in a Secret.
- **`SECURE=false` / `DEBUG_MODE=true` on maas-api** means `X-MaaS-Username`/`X-MaaS-Group`
  headers are trusted for key creation — anyone who can reach the service mints keys as
  anyone. Keep it cluster-internal (no Route — true today) and flip to `SECURE=true` when
  wiring a real identity provider.
- **`allow_public_admin: true`** exposes praxis's admin endpoint (:9901) on the pod. No
  Route points at it today; don't add one, or gate it.
- **`ALLOW_UNAUTHENTICATED_ADMIN=false`** (dashboard) must stay false outside local dev.
- The `maas-api` ClusterRole grants `get` on `secrets` by resourceName at cluster scope —
  acceptable-ish for dogfood, flag it if the cluster is shared.
- Postgres is single-DB, `sslmode=disable`, cluster-internal only. Fine inside a network
  policy'd namespace; add a `NetworkPolicy` so only praxis/maas-api/metering can reach it.
- Provider keys live in one Secret consumed by praxis env — correct pattern; just make
  sure that Secret never appears in the dashboard, logs, or CMs.

## 9. Environment-specific values in the live deployment (for reference, not copy-paste)

| Item | Live value | Fresh env |
|---|---|---|
| Namespace | `ai-gateway-dogfood` | ⟨pick⟩ |
| Apps domain | cluster-specific | `$APPS_DOMAIN` |
| Storage class | `ibmc-vpc-block-10iops-tier` | any RWO |
| Admin users | `yovadia@redhat.com, nitzikow@redhat.com, swatt@redhat.com` | ⟨pick⟩ |
| Monthly quota | 10,000,000,000 tokens | ⟨pick⟩ |
| Trusted group (fable access override) | `octo-eng` | ⟨pick⟩ |
| Subscription groups | `ai-eng`, `eco-eng`, `xe-eng`, `fcto-eng`, `octo-eng`, `prodsec-eng`, `cos-eng`, `ops-eng`, `ospo-eng`, `core-pe-eng`, `pnd-pe-eng`, `uie-eng`, `hybrid-pe-eng`, `ansible-pe-eng`, `hcm-pe-eng`, `cp-pe-eng`, `product-all`, `it-all`, `dogfood-testing`, `benchmark` | ⟨pick⟩ — Red Hat LDAP groups; invent names elsewhere |
| vLLM backend (Qwen3.8-27B) | `10.240.0.10:8000` | ⟨yours or delete⟩ |
| qwen-flash backend | nginx proxy → `qwen38-flash-next-….apps.emerg.pcbk.p1.openshiftapps.com` | ⟨yours or delete⟩ |

## 10. Source of truth

| Thing | Where |
|---|---|
| This guide | `docs/openshift-deploy-guide.md` |
| Live praxis routing | `oc get cm praxis-config -n ai-gateway-dogfood` |
| Live dashboard state | `oc get deploy metering-service -n ai-gateway-dogfood -o yaml` |
| Legacy (retired) arch | `docs/dogfood-runbook.md`, `docs/dogfood-env.md` — history only |
| Gateway source | Praxis AI image or pinned upstream source revision |
| Key server repo | `opendatahub-io/models-as-a-service`, build dir `maas-api/` |
| Dashboard source | `redhat-et/pricetag-metering` — deploy the approved image |
