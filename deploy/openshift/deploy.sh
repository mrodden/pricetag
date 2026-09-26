#!/usr/bin/env bash
# Idempotently deploy a PriceTag profile to OpenShift.
#
# Existing Secrets are preserved on repeat runs. Set ROTATE_SECRETS=true only
# when an intentional credential rotation is planned.

set -euo pipefail

NAMESPACE="${NAMESPACE:-ai-gateway-dogfood}"
PROFILE="${PROFILE:-dogfood}"
STORAGE_CLASS="${STORAGE_CLASS:-ibmc-vpc-block-10iops-tier}"
ROTATE_SECRETS="${ROTATE_SECRETS:-false}"
UPDATE_CONFIG="${UPDATE_CONFIG:-false}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE_DIR="$SCRIPT_DIR/overlays/$PROFILE"

: "${PRICETAG_KUBECONFIG:?Set PRICETAG_KUBECONFIG to a dedicated new-cluster kubeconfig}"
: "${EXPECTED_OC_SERVER:?Set EXPECTED_OC_SERVER to the new cluster API server}"
: "${PROTECTED_OC_SERVER:?Set PROTECTED_OC_SERVER to the production API server}"
: "${CONFIRM_DEPLOYMENT:?Set CONFIRM_DEPLOYMENT=true after checking the target}"
export KUBECONFIG="$PRICETAG_KUBECONFIG"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -f "$PRICETAG_KUBECONFIG" ]] || die "PRICETAG_KUBECONFIG does not point to a file"

oc whoami >/dev/null 2>&1 || die "not logged in to OpenShift"
ACTUAL_OC_SERVER="$(oc whoami --show-server)"
[[ "$ACTUAL_OC_SERVER" == "$EXPECTED_OC_SERVER" ]] || \
  die "connected server is $ACTUAL_OC_SERVER, expected $EXPECTED_OC_SERVER"
[[ "$ACTUAL_OC_SERVER" != "$PROTECTED_OC_SERVER" ]] || \
  die "refusing to mutate the protected production server"
[[ "$CONFIRM_DEPLOYMENT" == "true" ]] || \
  die "set CONFIRM_DEPLOYMENT=true only after verifying the target cluster"
command -v envsubst >/dev/null || die "envsubst not found"
[[ -d "$PROFILE_DIR" ]] || die "unknown profile: $PROFILE"

case "$PROFILE" in
  dogfood) expected_namespace=ai-gateway-dogfood ;;
  test) expected_namespace=pricetag-test ;;
  enmaas) expected_namespace=enmaas ;;
  *) die "unsupported profile: $PROFILE" ;;
esac
[[ "$NAMESPACE" == "$expected_namespace" ]] || \
  die "PROFILE=$PROFILE requires NAMESPACE=$expected_namespace"

ROUTE_DOMAIN="$(oc get ingress.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
[[ -n "$ROUTE_DOMAIN" ]] || die "could not determine the OpenShift route domain"
GATEWAY_HOST="${GATEWAY_HOST:-ai-gateway-${NAMESPACE}.${ROUTE_DOMAIN}}"
GATEWAY_URL="${GATEWAY_URL:-https://${GATEWAY_HOST}}"
export GATEWAY_HOST GATEWAY_URL

if [[ "$PROFILE" == enmaas ]]; then
  : "${AWS_ROLE_ARN:?Set AWS_ROLE_ARN to the EnMaaS CNPG backup role ARN}"
fi

[[ -n "${COS_BUCKET:-}" && -n "${COS_ENDPOINT:-}" && -n "${COS_REGION:-}" ]] || \
  die "COS_BUCKET, COS_ENDPOINT, and COS_REGION are required for the CNPG profile"
oc get storageclass "$STORAGE_CLASS" >/dev/null 2>&1 || \
  die "storage class not found: $STORAGE_CLASS"

secret_exists() { oc -n "$NAMESPACE" get secret "$1" >/dev/null 2>&1; }
config_exists() { oc -n "$NAMESPACE" get configmap "$1" >/dev/null 2>&1; }

oc apply -f "$PROFILE_DIR/namespace.yaml"

# The database password is generated once and then read back on every rerun.
if secret_exists aigateway-db-app; then
  PG_PASSWORD="$(oc -n "$NAMESPACE" get secret aigateway-db-app \
    -o jsonpath='{.data.password}' | base64 --decode)"
  [[ -n "$PG_PASSWORD" ]] || die "aigateway-db-app has no password"
else
  PG_PASSWORD="${PG_PASSWORD:-$(openssl rand -hex 32)}"
  oc -n "$NAMESPACE" create secret generic aigateway-db-app \
    --from-literal=username=aigateway \
    --from-literal=password="$PG_PASSWORD" \
    --dry-run=client -o yaml | oc apply -f -
fi

# These derived connection secrets are safe to reconcile on every run.
oc -n "$NAMESPACE" create secret generic postgresql-credentials \
  --from-literal=POSTGRES_USER=aigateway \
  --from-literal=POSTGRES_PASSWORD="$PG_PASSWORD" \
  --from-literal=POSTGRES_DB=aigateway \
  --from-literal=MAAS_DB_URL="postgresql://aigateway:${PG_PASSWORD}@aigateway-pg-rw:5432/aigateway?sslmode=disable" \
  --from-literal=METERING_DB_URL="postgresql://aigateway:${PG_PASSWORD}@aigateway-pg-rw:5432/aigateway?sslmode=disable" \
  --dry-run=client -o yaml | oc apply -f -

oc -n "$NAMESPACE" create secret generic maas-db-config \
  --from-literal=DB_CONNECTION_URL="postgresql://aigateway:${PG_PASSWORD}@aigateway-pg-rw:5432/aigateway?sslmode=disable" \
  --dry-run=client -o yaml | oc apply -f -

if ! secret_exists provider-credentials || [[ "$ROTATE_SECRETS" == true ]]; then
  for name in ANTHROPIC_API_KEY OPENAI_API_KEY LITELLM_API_KEY CB_LITELLM_API_KEY; do
    [[ -n "${!name:-}" ]] || die "$name is required to create provider-credentials"
  done
  oc -n "$NAMESPACE" create secret generic provider-credentials \
    --from-literal=ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
    --from-literal=OPENAI_API_KEY="$OPENAI_API_KEY" \
    --from-literal=LITELLM_API_KEY="$LITELLM_API_KEY" \
    --from-literal=CB_LITELLM_API_KEY="$CB_LITELLM_API_KEY" \
    --dry-run=client -o yaml | oc apply -f -
fi

# The EnMaaS Praxis deployment mounts its service-account JSON from a
# Secret. Preserve existing key material on reruns; rotate only from an
# explicitly supplied file when ROTATE_SECRETS=true.
if [[ "$PROFILE" == enmaas ]]; then
  [[ -n "${VERTEX_PROJECT:-}" ]] || die "VERTEX_PROJECT is required for PROFILE=enmaas"
  : "${PRAXIS_SOURCE_SHA:?Set PRAXIS_SOURCE_SHA to a pushed ET praxis-ai commit}"
  if [[ "${BUILD_PRAXIS_IMAGE:-true}" == true ]]; then
    VERTEX_IMAGE_TAG="$(NAMESPACE="$NAMESPACE" PRAXIS_SOURCE_SHA="$PRAXIS_SOURCE_SHA" \
      PRAXIS_SOURCE_REPO="${PRAXIS_SOURCE_REPO:-https://github.com/redhat-et/praxis-ai.git}" \
      PRAXIS_AI_FEATURES="${PRAXIS_AI_FEATURES:-full,gcp-adc-filter}" \
      "$SCRIPT_DIR/build-praxis-et.sh")"
    export VERTEX_IMAGE_TAG
  else
    : "${VERTEX_IMAGE_TAG:?Set VERTEX_IMAGE_TAG when BUILD_PRAXIS_IMAGE=false}"
  fi
  if ! secret_exists vertex-sa-key || [[ "$ROTATE_SECRETS" == true || "${ROTATE_VERTEX_SA_KEY:-false}" == true ]]; then
    [[ -n "${VERTEX_SA_KEY_FILE:-}" && -f "$VERTEX_SA_KEY_FILE" ]] || \
      die "VERTEX_SA_KEY_FILE must point to the Vertex service-account JSON file to create/rotate vertex-sa-key"
    oc -n "$NAMESPACE" create secret generic vertex-sa-key \
      --from-file="sa-key.json=$VERTEX_SA_KEY_FILE" \
      --dry-run=client -o yaml | oc -n "$NAMESPACE" apply -f -
  fi
fi

if [[ "$PROFILE" != enmaas ]] && \
  (! secret_exists cnpg-backup-cos || [[ "$ROTATE_SECRETS" == true ]]); then
  for name in COS_ACCESS_KEY_ID COS_SECRET_ACCESS_KEY; do
    [[ -n "${!name:-}" ]] || die "$name is required to create cnpg-backup-cos"
  done
  oc -n "$NAMESPACE" create secret generic cnpg-backup-cos \
    --from-literal=ACCESS_KEY_ID="$COS_ACCESS_KEY_ID" \
    --from-literal=SECRET_ACCESS_KEY="$COS_SECRET_ACCESS_KEY" \
    --dry-run=client -o yaml | oc apply -f -
fi

if ! config_exists pricetag-config || [[ "$UPDATE_CONFIG" == true ]]; then
  for name in ADMIN_USERS SUPERADMIN_USERS MAAS_SECURE MAAS_DEBUG_MODE \
    QWEN_ENDPOINT CB_GLM_ENDPOINT; do
    [[ -n "${!name:-}" ]] || die "$name is required to create pricetag-config"
  done
  oc -n "$NAMESPACE" create configmap pricetag-config \
    --from-literal=ADMIN_USERS="$ADMIN_USERS" \
    --from-literal=SUPERADMIN_USERS="$SUPERADMIN_USERS" \
    --from-literal=MAAS_SECURE="$MAAS_SECURE" \
    --from-literal=MAAS_DEBUG_MODE="$MAAS_DEBUG_MODE" \
    --dry-run=client -o yaml | oc apply -f -
fi

if ! secret_exists pricetag-session || [[ "$ROTATE_SECRETS" == true ]]; then
  SESSION_SECRET="${SESSION_SECRET:-$(openssl rand -hex 32)}"
  oc -n "$NAMESPACE" create secret generic pricetag-session \
    --from-literal=SESSION_SECRET="$SESSION_SECRET" \
    --dry-run=client -o yaml | oc apply -f -
fi

# Cluster-scoped CRDs and the pinned CNPG operator are apply-safe. The operator
# is installed once per cluster; the namespaced Cluster is safe to reconcile.
for crd in "$SCRIPT_DIR"/crds/*.yaml; do
  oc apply -f "$crd"
done
# The vendored CNPG CRDs exceed the client-side apply annotation limit.
# Server-side apply keeps the schema in managed fields instead.
oc apply --server-side --force-conflicts \
  --field-manager=pricetag-deploy \
  -f "$SCRIPT_DIR/database/cnpg/cnpg-operator-1.30.0.yaml"
oc -n cnpg-system rollout status deploy/cnpg-controller-manager --timeout=300s

export NAMESPACE STORAGE_CLASS COS_BUCKET COS_ENDPOINT COS_REGION
CNPG_CLUSTER_MANIFEST="$SCRIPT_DIR/database/cnpg/10-cluster.yaml"
CNPG_ENV_VARS="\${NAMESPACE} \${STORAGE_CLASS} \${COS_BUCKET} \${COS_ENDPOINT} \${COS_REGION}"
if [[ "$PROFILE" == enmaas ]]; then
  export AWS_ROLE_ARN
  CNPG_CLUSTER_MANIFEST="$SCRIPT_DIR/database/cnpg/10-cluster-enmaas.yaml"
  CNPG_ENV_VARS="\${NAMESPACE} \${STORAGE_CLASS} \${COS_BUCKET} \${COS_ENDPOINT} \${COS_REGION} \${AWS_ROLE_ARN}"
fi
envsubst "$CNPG_ENV_VARS" < "$CNPG_CLUSTER_MANIFEST" | oc apply -f -
envsubst "\${NAMESPACE}" \
  < "$SCRIPT_DIR/database/cnpg/20-scheduled-backup.yaml" | oc apply -f -
oc -n "$NAMESPACE" wait clusters.postgresql.cnpg.io/aigateway-pg \
  --for=condition=Ready --timeout=10m

binding_name=""
case "$PROFILE" in
  dogfood) binding_name=pricetag-maas-api-dogfood ;;
  test) binding_name=pricetag-maas-api-test ;;
  enmaas) binding_name=pricetag-maas-api-enmaas ;;
esac
if [[ -n "$binding_name" ]] && \
  [[ "$(oc get clusterrolebinding "$binding_name" -o jsonpath='{.roleRef.name}' 2>/dev/null || true)" == maas-api ]]; then
  # The old manifest used a generic ClusterRole name. Delete only that exact
  # binding so the immutable roleRef can be recreated with the prefixed role.
  oc delete clusterrolebinding "$binding_name"
fi

RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "$RENDER_DIR"' EXIT
oc kustomize "$PROFILE_DIR" > "$RENDER_DIR/manifests.yaml"
if [[ "$PROFILE" == enmaas ]]; then
  command -v python3 >/dev/null || die "python3 is required to render the EnMaaS Vertex config fragments"
  python3 "$SCRIPT_DIR/render-enmaas-vertex.py" \
    "$RENDER_DIR/manifests.yaml" "$PROFILE_DIR/vertex-fragments" \
    > "$RENDER_DIR/with-vertex.yaml"
  mv "$RENDER_DIR/with-vertex.yaml" "$RENDER_DIR/manifests.yaml"
fi
envsubst "\${NAMESPACE} \${QWEN_ENDPOINT} \${CB_GLM_ENDPOINT} \${GATEWAY_HOST} \${GATEWAY_URL} \${VERTEX_PROJECT} \${VERTEX_IMAGE_TAG}" \
  < "$RENDER_DIR/manifests.yaml" | oc apply -f -

oc -n "$NAMESPACE" rollout status deployment/maas-api --timeout=180s
oc -n "$NAMESPACE" rollout status deployment/metering-service --timeout=180s
oc -n "$NAMESPACE" rollout status deployment/praxis --timeout=180s

# Wait for every path route to be admitted before retiring old gateway hosts.
# Route status keeps conditions under status.ingress, so oc wait's generic
# condition handler is not reliable here.
for route in ai-gateway ai-gateway-chat-completions ai-gateway-responses \
  ai-gateway-conversations ai-gateway-models; do
  admitted=false
  for _ in {1..120}; do
    if [[ "$(oc -n "$NAMESPACE" get route "$route" \
      -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}')" == True ]]; then
      admitted=true
      break
    fi
    sleep 1
  done
  [[ "$admitted" == true ]] || die "route was not admitted: $route"
done

# Remove the former public gateway hostnames after the canonical path-routed
# host and workloads are ready. The path routes above preserve each API.
for legacy_route in ai-gateway-anthropic ai-gateway-openai ai-gateway-unified ai-gateway-benchmark; do
  oc -n "$NAMESPACE" delete route "$legacy_route" --ignore-not-found=true
done

printf '\nPriceTag deployed to %s (%s)\n' "$NAMESPACE" "$PROFILE"
printf 'Gateway: %s\n' "$GATEWAY_URL"
oc -n "$NAMESPACE" get pods
