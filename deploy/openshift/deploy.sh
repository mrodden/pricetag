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
DATABASE_BACKEND="${DATABASE_BACKEND:-cnpg}"
METERING_MODEL_POLICY_CHECK="${METERING_MODEL_POLICY_CHECK:-false}"
export METERING_MODEL_POLICY_CHECK
METERING_INTERNAL_AUTH_CHANGED=false
METERING_PARTNER_API_CHANGED=false
METERING_USER_MANAGEMENT_API_CHANGED=false
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE_DIR="$SCRIPT_DIR/overlays/$PROFILE"

: "${PRICETAG_KUBECONFIG:?Set PRICETAG_KUBECONFIG to a dedicated new-cluster kubeconfig}"
: "${EXPECTED_OC_SERVER:?Set EXPECTED_OC_SERVER to the new cluster API server}"
: "${PROTECTED_OC_SERVER:?Set PROTECTED_OC_SERVER to the production API server}"
: "${CONFIRM_DEPLOYMENT:?Set CONFIRM_DEPLOYMENT=true after checking the target}"
export KUBECONFIG="$PRICETAG_KUBECONFIG"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$METERING_MODEL_POLICY_CHECK" == true || "$METERING_MODEL_POLICY_CHECK" == false ]] || \
  die "METERING_MODEL_POLICY_CHECK must be true or false"

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
case "$DATABASE_BACKEND" in
  cnpg|rds) ;;
  *) die "DATABASE_BACKEND must be cnpg or rds" ;;
esac
if [[ "$DATABASE_BACKEND" == rds ]]; then
  : "${RDS_EGRESS_CIDR:?Set RDS_EGRESS_CIDR to the approved RDS subnet or endpoint CIDR}"
else
  # The EnMaaS overlay still renders this field in CNPG mode; use a reserved,
  # unroutable test CIDR so it cannot accidentally grant external access.
  RDS_EGRESS_CIDR="${RDS_EGRESS_CIDR:-192.0.2.1/32}"
fi
validate_rds_cidr() {
  RDS_EGRESS_CIDR="$RDS_EGRESS_CIDR" python3 - <<'PY'
import ipaddress
import os
import sys

value = os.environ["RDS_EGRESS_CIDR"]
try:
    network = ipaddress.ip_network(value, strict=False)
except ValueError as exc:
    print(f"ERROR: RDS_EGRESS_CIDR is not a valid CIDR: {exc}", file=sys.stderr)
    raise SystemExit(1)
if network.prefixlen == 0:
    print("ERROR: RDS_EGRESS_CIDR must not be a default route", file=sys.stderr)
    raise SystemExit(1)
PY
}

validate_rds_cidr

validate_rds_url() {
  local variable_name="$1"
  local url_value="$2"
  RDS_URL="$url_value" RDS_EXPECTED_HOST="$RDS_EXPECTED_HOST" \
    RDS_URL_NAME="$variable_name" python3 - <<'PY'
import os
import sys
from urllib.parse import parse_qs, urlsplit

name = os.environ["RDS_URL_NAME"]
value = os.environ["RDS_URL"]
expected = os.environ["RDS_EXPECTED_HOST"].rstrip(".").lower()
try:
    parsed = urlsplit(value)
    host = (parsed.hostname or "").rstrip(".").lower()
    port = parsed.port
except ValueError as exc:
    print(f"ERROR: {name} is not a valid PostgreSQL URL: {exc}", file=sys.stderr)
    raise SystemExit(1)

if parsed.scheme not in {"postgres", "postgresql"}:
    print(f"ERROR: {name} must use the PostgreSQL URL scheme", file=sys.stderr)
    raise SystemExit(1)
if host != expected:
    print(f"ERROR: {name} host does not match RDS_EXPECTED_HOST", file=sys.stderr)
    raise SystemExit(1)
if port not in {None, 5432}:
    print(f"ERROR: {name} must use PostgreSQL port 5432", file=sys.stderr)
    raise SystemExit(1)
sslmode = parse_qs(parsed.query).get("sslmode", [""])[-1]
if sslmode not in {"require", "verify-ca", "verify-full"}:
    print(f"ERROR: {name} must require TLS with sslmode=require, verify-ca, or verify-full", file=sys.stderr)
    raise SystemExit(1)
PY
}

# Validate the external database target before any namespace or application
# Secret is reconciled. This guard protects against sending an EnMaaS deploy to
# an unintended database even when the OpenShift target itself is correct.
if [[ "$DATABASE_BACKEND" == rds ]]; then
  [[ "$PROFILE" == enmaas ]] || die "DATABASE_BACKEND=rds is only supported for PROFILE=enmaas"
  : "${RDS_DATABASE_URL:?Set RDS_DATABASE_URL when DATABASE_BACKEND=rds}"
  : "${RDS_READ_DATABASE_URL:?Set RDS_READ_DATABASE_URL when DATABASE_BACKEND=rds}"
  : "${RDS_EXPECTED_HOST:?Set RDS_EXPECTED_HOST to the approved EnMaaS RDS hostname}"
  [[ "$RDS_EXPECTED_HOST" != */* && "$RDS_EXPECTED_HOST" != *:* ]] || \
    die "RDS_EXPECTED_HOST must be a hostname, not a URL or path"
  validate_rds_url RDS_DATABASE_URL "$RDS_DATABASE_URL"
  validate_rds_url RDS_READ_DATABASE_URL "$RDS_READ_DATABASE_URL"
  validate_rds_url RDS_MAAS_DATABASE_URL "${RDS_MAAS_DATABASE_URL:-$RDS_DATABASE_URL}"
  validate_rds_url RDS_METERING_DATABASE_URL "${RDS_METERING_DATABASE_URL:-$RDS_DATABASE_URL}"
fi

ROUTE_DOMAIN="$(oc get ingress.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
[[ -n "$ROUTE_DOMAIN" ]] || die "could not determine the OpenShift route domain"
KUBE_DNS_SERVICE_IP="$(oc -n openshift-dns get service dns-default -o jsonpath='{.spec.clusterIP}')"
KUBE_API_SERVICE_IP="$(oc -n default get service kubernetes -o jsonpath='{.spec.clusterIP}')"
KUBE_API_ENDPOINT_IP="$(oc -n default get endpoints kubernetes -o jsonpath='{.subsets[0].addresses[0].ip}')"
for value in KUBE_DNS_SERVICE_IP KUBE_API_SERVICE_IP KUBE_API_ENDPOINT_IP; do
  [[ "${!value}" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die "$value is not a valid IPv4 address"
done
GATEWAY_HOST="${GATEWAY_HOST:-ai-gateway-${NAMESPACE}.${ROUTE_DOMAIN}}"
GATEWAY_URL="${GATEWAY_URL:-https://${GATEWAY_HOST}}"
DASHBOARD_HOST="${DASHBOARD_HOST:-dashboard-${NAMESPACE}.${ROUTE_DOMAIN}}"
export GATEWAY_HOST GATEWAY_URL DASHBOARD_HOST KUBE_DNS_SERVICE_IP KUBE_API_SERVICE_IP KUBE_API_ENDPOINT_IP

if [[ "$PROFILE" == enmaas ]]; then
  : "${AWS_ROLE_ARN:?Set AWS_ROLE_ARN to the EnMaaS CNPG backup role ARN}"
fi

METERING_INTERNAL_AUTH_CHANGED=false

[[ -n "${COS_BUCKET:-}" && -n "${COS_ENDPOINT:-}" && -n "${COS_REGION:-}" ]] || \
  die "COS_BUCKET, COS_ENDPOINT, and COS_REGION are required for the CNPG profile"
oc get storageclass "$STORAGE_CLASS" >/dev/null 2>&1 || \
  die "storage class not found: $STORAGE_CLASS"

secret_exists() { oc -n "$NAMESPACE" get secret "$1" >/dev/null 2>&1; }
config_exists() { oc -n "$NAMESPACE" get configmap "$1" >/dev/null 2>&1; }
sha256_hex() {
  if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi | awk '{print $1}'
}

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

# These derived connection secrets are safe to reconcile on every run. In RDS
# mode, complete URLs are supplied by the operations environment; credentials
# never enter a tracked manifest. The CNPG password is still maintained so a
# retained CNPG cluster remains a rollback target.
if [[ "$DATABASE_BACKEND" == rds ]]; then
  MAAS_DATABASE_URL="${RDS_MAAS_DATABASE_URL:-$RDS_DATABASE_URL}"
  METERING_DATABASE_URL="${RDS_METERING_DATABASE_URL:-$RDS_DATABASE_URL}"
else
  MAAS_DATABASE_URL="postgresql://aigateway:${PG_PASSWORD}@aigateway-pg-rw:5432/aigateway?sslmode=disable"
  METERING_DATABASE_URL="$MAAS_DATABASE_URL"
fi
oc -n "$NAMESPACE" create secret generic postgresql-credentials \
  --from-literal=POSTGRES_USER=aigateway \
  --from-literal=POSTGRES_PASSWORD="$PG_PASSWORD" \
  --from-literal=POSTGRES_DB=aigateway \
  --from-literal=MAAS_DB_URL="$MAAS_DATABASE_URL" \
  --from-literal=METERING_DB_URL="$METERING_DATABASE_URL" \
  --dry-run=client -o yaml | oc apply -f -

oc -n "$NAMESPACE" create secret generic maas-db-config \
  --from-literal=DB_CONNECTION_URL="$MAAS_DATABASE_URL" \
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
    VERTEX_IMAGE_DIGEST="$(oc -n "$NAMESPACE" get istag "praxis-ai:${VERTEX_IMAGE_TAG}" \
      -o jsonpath='{.image.dockerImageReference}' | sed 's/.*@//')"
    [[ "$VERTEX_IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || \
      die "Praxis build output has no immutable image digest"
    export VERTEX_IMAGE_DIGEST
  else
    : "${VERTEX_IMAGE_DIGEST:?Set VERTEX_IMAGE_DIGEST when BUILD_PRAXIS_IMAGE=false}"
  fi
  : "${METERING_SOURCE_SHA:?Set METERING_SOURCE_SHA to a pushed pricetag-metering commit}"
  if [[ "${BUILD_METERING_IMAGE:-true}" == true ]]; then
    METERING_IMAGE_TAG="$(NAMESPACE="$NAMESPACE" METERING_SOURCE_SHA="$METERING_SOURCE_SHA" \
      METERING_SOURCE_REPO="${METERING_SOURCE_REPO:-https://github.com/redhat-et/pricetag-metering.git}" \
      "$SCRIPT_DIR/build-metering-et.sh")"
    export METERING_IMAGE_TAG
    METERING_IMAGE_DIGEST="$(oc -n "$NAMESPACE" get istag "metering-service:${METERING_IMAGE_TAG}" \
      -o jsonpath='{.image.dockerImageReference}' | sed 's/.*@//')"
    export METERING_IMAGE_DIGEST
  else
    : "${METERING_IMAGE_TAG:?Set METERING_IMAGE_TAG when BUILD_METERING_IMAGE=false}"
    : "${METERING_IMAGE_DIGEST:?Set METERING_IMAGE_DIGEST when BUILD_METERING_IMAGE=false}"
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

# The metering service's gateway-facing entitlement and event APIs use a
# private bearer token. Preserve it across reruns; rotate only when explicitly
# requested so a gateway rollout cannot invalidate active traffic unexpectedly.
if [[ "$PROFILE" == enmaas ]] && \
   (! secret_exists metering-internal-auth || [[ "${ROTATE_METERING_INTERNAL_AUTH:-false}" == true ]]); then
  METERING_INTERNAL_TOKEN="${METERING_INTERNAL_TOKEN:-$(openssl rand -hex 32)}"
  oc -n "$NAMESPACE" create secret generic metering-internal-auth \
    --from-literal=token="$METERING_INTERNAL_TOKEN" \
    --dry-run=client -o yaml | oc -n "$NAMESPACE" apply -f -
  METERING_INTERNAL_AUTH_CHANGED=true
fi

# External usage-report and user-model-policy APIs each require their own
# bearer credential. Preserve existing credentials on reruns; rotate only when
# explicitly requested. Values may be supplied by a secret manager, otherwise
# generate high-entropy tokens without printing them to the console.
if [[ "$PROFILE" == enmaas ]] && \
   (! secret_exists metering-partner-api || [[ "${ROTATE_METERING_PARTNER_API_SECRETS:-false}" == true ]]); then
  (
    umask 077
    secret_dir="$(mktemp -d)"
    trap 'rm -rf "$secret_dir"' EXIT
    usage_report_secret="${USAGE_REPORT_API_SECRET:-$(openssl rand -hex 32)}"
    model_policy_secret="${MODEL_POLICY_API_SECRET:-$(openssl rand -hex 32)}"
    printf '%s' "$usage_report_secret" >"$secret_dir/usage-report"
    printf '%s' "$model_policy_secret" >"$secret_dir/model-policy"
    unset usage_report_secret model_policy_secret USAGE_REPORT_API_SECRET MODEL_POLICY_API_SECRET
    oc -n "$NAMESPACE" create secret generic metering-partner-api \
      --from-file=usage-report="$secret_dir/usage-report" \
      --from-file=model-policy="$secret_dir/model-policy" \
      --dry-run=client -o yaml | oc -n "$NAMESPACE" apply -f -
  )
  METERING_PARTNER_API_CHANGED=true
fi

# User directory and key issuance have a dedicated credential: this secret can
# mutate user tags and mint/revoke MaaS keys, so it is not shared with report or
# model-policy consumers. Preserve it on reruns and rotate only deliberately.
if [[ "$PROFILE" == enmaas ]] && \
   (! secret_exists metering-user-management-api || [[ "${ROTATE_METERING_USER_MANAGEMENT_API_SECRET:-false}" == true ]]); then
  (
    umask 077
    secret_dir="$(mktemp -d)"
    trap 'rm -rf "$secret_dir"' EXIT
    user_management_secret="${USER_MANAGEMENT_API_SECRET:-$(openssl rand -hex 32)}"
    printf '%s' "$user_management_secret" >"$secret_dir/token"
    unset user_management_secret USER_MANAGEMENT_API_SECRET
    oc -n "$NAMESPACE" create secret generic metering-user-management-api \
      --from-file=token="$secret_dir/token" \
      --dry-run=client -o yaml | oc -n "$NAMESPACE" apply -f -
  )
  METERING_USER_MANAGEMENT_API_CHANGED=true
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

export NAMESPACE STORAGE_CLASS COS_BUCKET COS_ENDPOINT COS_REGION RDS_EGRESS_CIDR
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

if [[ "$PROFILE" == enmaas ]]; then
  if [[ "$DATABASE_BACKEND" == rds ]]; then
    oc -n "$NAMESPACE" create secret generic metering-readonly-db-url \
      --from-literal=READ_DATABASE_URL="$RDS_READ_DATABASE_URL" \
      --dry-run=client -o yaml | oc -n "$NAMESPACE" apply -f -
  else
  if ! secret_exists metering-reader-password || [[ "${ROTATE_METERING_READER_PASSWORD:-false}" == true ]]; then
    METERING_READER_PASSWORD="${METERING_READER_PASSWORD:-$(openssl rand -hex 32)}"
    oc -n "$NAMESPACE" create secret generic metering-reader-password \
      --from-literal=username=metering_reader \
      --from-literal=password="$METERING_READER_PASSWORD" \
      --dry-run=client -o yaml | oc -n "$NAMESPACE" apply -f -
  fi
  oc -n "$NAMESPACE" apply -f "$SCRIPT_DIR/database/readonly-replica/10-databaserole.yaml"
  for _ in $(seq 1 60); do
    if [[ "$(oc -n "$NAMESPACE" get databaserole metering-reader \
      -o jsonpath='{.status.applied}' 2>/dev/null || true)" == true ]]; then
      break
    fi
    sleep 2
  done
  [[ "$(oc -n "$NAMESPACE" get databaserole metering-reader \
    -o jsonpath='{.status.applied}' 2>/dev/null || true)" == true ]] || \
    die "metering-reader DatabaseRole did not become applied"
  oc -n "$NAMESPACE" exec -i aigateway-pg-1 -- psql -U postgres -d aigateway \
    -v ON_ERROR_STOP=1 -f - < "$SCRIPT_DIR/database/readonly-replica/20-grants.sql"
  READER_PASSWORD="$(oc -n "$NAMESPACE" get secret metering-reader-password \
    -o jsonpath='{.data.password}' | base64 --decode)"
  oc -n "$NAMESPACE" create secret generic metering-readonly-db-url \
    --from-literal=READ_DATABASE_URL="postgresql://metering_reader:${READER_PASSWORD}@aigateway-pg-r:5432/aigateway?sslmode=disable" \
    --dry-run=client -o yaml | oc -n "$NAMESPACE" apply -f -
  fi
fi

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
envsubst "\${NAMESPACE} \${QWEN_ENDPOINT} \${CB_GLM_ENDPOINT} \${GATEWAY_HOST} \${GATEWAY_URL} \${DASHBOARD_HOST} \${VERTEX_PROJECT} \${VERTEX_IMAGE_DIGEST} \${METERING_IMAGE_DIGEST} \${RDS_EGRESS_CIDR} \${KUBE_DNS_SERVICE_IP} \${KUBE_API_SERVICE_IP} \${KUBE_API_ENDPOINT_IP}" \
  < "$RENDER_DIR/manifests.yaml" | oc apply -f -

# The dashboard Route receives its host from OpenShift. Pass that canonical
# host into the embedded welcome page so its Dashboard link never falls back
# to the template placeholder. This is deliberately derived after apply: the
# route host is not known when the static manifest is rendered.
dashboard_host="$(oc -n "$NAMESPACE" get route dashboard-welcome -o jsonpath='{.spec.host}')"
[[ -n "$dashboard_host" ]] || die "dashboard Route has no host"
oc -n "$NAMESPACE" set env deployment/metering-service \
  "WELCOME_DASHBOARD_URL=https://${dashboard_host}" >/dev/null

# Praxis reads praxis-config once at startup, so applying a changed ConfigMap
# alone leaves running pods on the previous pipelines (for example without the
# metering internal-auth header). Pin the checksum of the applied config on the
# pod template: a changed config rolls Praxis through its normal RollingUpdate,
# an unchanged config is a no-op patch and does not restart anything.
if [[ "$PROFILE" == enmaas ]]; then
  praxis_config_checksum="$(oc -n "$NAMESPACE" get configmap praxis-config \
    -o jsonpath='{.data.praxis\.yaml}' | sha256_hex)"
  [[ "$praxis_config_checksum" =~ ^[0-9a-f]{64}$ ]] || die "could not compute praxis-config checksum"
  oc -n "$NAMESPACE" patch deployment/praxis --type=merge -p \
    "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"pricetag.io/praxis-config-checksum\":\"sha256:${praxis_config_checksum}\"}}}}}" \
    >/dev/null
fi

if [[ "$PROFILE" == enmaas && "$METERING_INTERNAL_AUTH_CHANGED" == true ]]; then
  oc -n "$NAMESPACE" rollout restart deployment/metering-service deployment/praxis
fi
if [[ "$PROFILE" == enmaas && "$METERING_PARTNER_API_CHANGED" == true ]]; then
  oc -n "$NAMESPACE" rollout restart deployment/metering-service
fi
if [[ "$PROFILE" == enmaas && "$METERING_USER_MANAGEMENT_API_CHANGED" == true ]]; then
  oc -n "$NAMESPACE" rollout restart deployment/metering-service
fi

oc -n "$NAMESPACE" rollout status deployment/maas-api --timeout=180s
oc -n "$NAMESPACE" rollout status deployment/metering-service --timeout=180s
oc -n "$NAMESPACE" rollout status deployment/praxis --timeout=180s

# Wait for every path route to be admitted before retiring old gateway hosts.
# Route status keeps conditions under status.ingress, so oc wait's generic
# condition handler is not reliable here.
required_routes=(ai-gateway ai-gateway-chat-completions ai-gateway-responses \
  ai-gateway-conversations ai-gateway-models dashboard-api-usage \
  dashboard-api-model-policies)
for route in "${required_routes[@]}"; do
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
