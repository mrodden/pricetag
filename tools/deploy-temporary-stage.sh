#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
EXPECTED_SERVER="https://api.models-arch-ocp.ijxt.p3.openshiftapps.com:443"
PRODUCTION_SERVER="https://api.enmaas-prod.187f.p3.openshiftapps.com:443"
NS=enmaas-stage

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
actual="$(oc whoami --show-server 2>/dev/null)" || die "not logged in"
[[ "$actual" == "$EXPECTED_SERVER" && "$actual" != "$PRODUCTION_SERVER" ]] || die "wrong cluster: $actual"
[[ "${CONFIRM_STAGE_WORKLOAD_DEPLOY:-false}" == true ]] || die "set CONFIRM_STAGE_WORKLOAD_DEPLOY=true"
oc -n "$NS" get configmap enmaas-stage-images >/dev/null || die "stage images are not built"

echo "==> install MaaS CRDs and CNPG operator on non-production stage cluster"
for crd in "$ROOT"/deploy/openshift/crds/*.yaml; do oc apply -f "$crd" >/dev/null; done
if ! oc get crd clusters.postgresql.cnpg.io >/dev/null 2>&1; then
  oc apply --server-side --force-conflicts --field-manager=enmaas-stage-deploy \
    -f "$ROOT/deploy/openshift/database/cnpg/cnpg-operator-1.30.0.yaml" >/dev/null
fi
oc -n cnpg-system rollout status deploy/cnpg-controller-manager --timeout=5m

secret_exists() { oc -n "$NS" get secret "$1" >/dev/null 2>&1; }
if ! secret_exists aigateway-db-app; then
  pg_password="$(openssl rand -hex 24)"
  oc -n "$NS" create secret generic aigateway-db-app \
    --from-literal=username=aigateway --from-literal=password="$pg_password" >/dev/null
  dsn="postgresql://aigateway:${pg_password}@aigateway-pg-rw:5432/aigateway?sslmode=disable"
  oc -n "$NS" create secret generic postgresql-credentials \
    --from-literal=POSTGRES_USER=aigateway --from-literal=POSTGRES_PASSWORD="$pg_password" \
    --from-literal=POSTGRES_DB=aigateway --from-literal=MAAS_DB_URL="$dsn" \
    --from-literal=METERING_DB_URL="$dsn" >/dev/null
  oc -n "$NS" create secret generic maas-db-config --from-literal=DB_CONNECTION_URL="$dsn" >/dev/null
  oc -n "$NS" create secret generic metering-readonly-db-url --from-literal=READ_DATABASE_URL="$dsn" >/dev/null
  unset pg_password dsn
fi
if ! secret_exists provider-credentials; then
  oc -n "$NS" create secret generic provider-credentials \
    --from-literal=ANTHROPIC_API_KEY=stage-disabled \
    --from-literal=OPENAI_API_KEY=stage-disabled \
    --from-literal=CB_LITELLM_API_KEY=stage-disabled >/dev/null
fi
if ! secret_exists pricetag-session; then
  oc -n "$NS" create secret generic pricetag-session --from-literal=SESSION_SECRET="$(openssl rand -hex 32)" >/dev/null
fi
if ! secret_exists metering-user-management-api; then
  oc -n "$NS" create secret generic metering-user-management-api --from-literal=token="$(openssl rand -hex 32)" >/dev/null
fi
if ! secret_exists metering-partner-api; then
  oc -n "$NS" create secret generic metering-partner-api \
    --from-literal=usage-report="$(openssl rand -hex 32)" \
    --from-literal=usage-report-air="$(openssl rand -hex 32)" \
    --from-literal=usage-report-aibt="$(openssl rand -hex 32)" \
    --from-literal=model-policy="$(openssl rand -hex 32)" \
    --from-literal=model-policy-aibt="$(openssl rand -hex 32)" \
    --from-literal=model-catalog="$(openssl rand -hex 32)" \
    --from-literal=model-catalog-aibt="$(openssl rand -hex 32)" >/dev/null
fi
oc -n "$NS" create configmap pricetag-config \
  --from-literal=ADMIN_USERS="${STAGE_ADMIN_USERS:-bturner@redhat.com}" \
  --from-literal=SUPERADMIN_USERS="${STAGE_SUPERADMIN_USERS:-bturner@redhat.com}" \
  --from-literal=MAAS_SECURE=false --from-literal=MAAS_DEBUG_MODE=false \
  --dry-run=client -o yaml | oc apply -f - >/dev/null

echo "==> single-instance stage CNPG"
# The operator must reach the instance manager on 8000 before the Cluster can
# become Ready. Apply policies before creating/waiting for the Cluster; the
# remaining workload objects are still rendered and reviewed later.
oc -n "$NS" apply -f "$ROOT/deploy/openshift/overlays/stage/network-policy.yaml"
oc apply -f "$ROOT/deploy/openshift/database/cnpg/10-cluster-stage.yaml"
oc -n "$NS" wait cluster/aigateway-pg --for=condition=Ready --timeout=10m

route_domain="$(oc get ingress.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
export GATEWAY_HOST="ai-gateway-${NS}.${route_domain}"
export GATEWAY_URL="https://${GATEWAY_HOST}"
export DASHBOARD_HOST="dashboard-${NS}.${route_domain}"
export QWEN_ENDPOINT=stage-disabled.invalid
export CB_GLM_ENDPOINT=stage-disabled.invalid
render_dir="$(mktemp -d)"; trap 'rm -rf "$render_dir"' EXIT
kubectl kustomize "$ROOT/deploy/openshift/overlays/stage" >"$render_dir/kustomized.yaml"
envsubst '${GATEWAY_HOST} ${GATEWAY_URL} ${DASHBOARD_HOST} ${QWEN_ENDPOINT} ${CB_GLM_ENDPOINT}' \
  <"$render_dir/kustomized.yaml" >"$render_dir/final.yaml"
if grep -n '\${' "$render_dir/final.yaml"; then die "unresolved manifest variables"; fi

echo "==> server dry-run and diff"
oc apply --dry-run=server -f "$render_dir/final.yaml" >/dev/null
oc diff -f "$render_dir/final.yaml" || diff_status=$?
[[ "${diff_status:-0}" == 0 || "${diff_status:-0}" == 1 ]] || die "oc diff failed"
echo "==> apply stage workloads"
oc apply -f "$render_dir/final.yaml"
for deployment in maas-api metering-service praxis; do
  oc -n "$NS" rollout status "deploy/$deployment" --timeout=5m
done

echo "==> stage routes"
oc -n "$NS" get route -o custom-columns='NAME:.metadata.name,HOST:.spec.host,ADMITTED:.status.ingress[0].conditions[0].status'
echo "GATEWAY_URL=$GATEWAY_URL"
echo "DASHBOARD_URL=https://$DASHBOARD_HOST"
