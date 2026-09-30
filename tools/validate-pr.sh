#!/usr/bin/env bash
set -euo pipefail

# Fast, non-mutating Pull Request validation. This intentionally does not log
# into OpenShift, build images, contact providers, or use deployment Secrets.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

export NAMESPACE=enmaas
export VERTEX_PROJECT=ci-placeholder-project
export VERTEX_IMAGE_TAG=practice-ci
export VERTEX_IMAGE_DIGEST=sha256:1111111111111111111111111111111111111111111111111111111111111111
export METERING_IMAGE_DIGEST=sha256:0000000000000000000000000000000000000000000000000000000000000000
export GATEWAY_HOST=ai-gateway-enmaas.apps.ci.example.com
export GATEWAY_URL=https://$GATEWAY_HOST
export DASHBOARD_HOST=dashboard-enmaas.apps.ci.example.com
export RDS_EGRESS_CIDR=192.0.2.1/32
export METERING_MODEL_POLICY_CHECK=true
export KUBE_DNS_SERVICE_IP=172.30.0.10
export KUBE_API_SERVICE_IP=172.30.0.1
export KUBE_API_ENDPOINT_IP=172.20.0.1
export QWEN_ENDPOINT=qwen.ci.example.com
export CB_GLM_ENDPOINT=glm.ci.example.com

cd "$ROOT_DIR"

echo "== shell syntax =="
while IFS= read -r -d '' script; do
  bash -n "$script"
done < <(find deploy tools -type f -name '*.sh' -print0)

echo "== Python syntax =="
while IFS= read -r -d '' source; do
  python3 -m py_compile "$source"
done < <(find deploy tools -type f -name '*.py' -print0)

echo "== whitespace =="
git diff --check

echo "== deployment guard =="
grep -q 'PRICETAG_KUBECONFIG' deploy/openshift/deploy.sh
grep -q 'EXPECTED_OC_SERVER' deploy/openshift/deploy.sh
grep -q 'PROTECTED_OC_SERVER' deploy/openshift/deploy.sh
grep -q 'CONFIRM_DEPLOYMENT' deploy/openshift/deploy.sh

echo "== Kustomize profiles =="
for profile in test dogfood enmaas; do
  kubectl kustomize "deploy/openshift/overlays/$profile" >"$TMP_DIR/$profile.yaml"
  yq eval '.' "$TMP_DIR/$profile.yaml" >/dev/null
done

echo "== EnMaaS rendered Praxis configuration =="
kubectl kustomize deploy/openshift/overlays/enmaas >"$TMP_DIR/enmaas-kustomized.yaml"
python3 deploy/openshift/render-enmaas-vertex.py \
  "$TMP_DIR/enmaas-kustomized.yaml" \
  deploy/openshift/overlays/enmaas/vertex-fragments \
  >"$TMP_DIR/enmaas-vertex.yaml"
envsubst '${NAMESPACE} ${QWEN_ENDPOINT} ${CB_GLM_ENDPOINT} ${GATEWAY_HOST} ${GATEWAY_URL} ${DASHBOARD_HOST} ${VERTEX_PROJECT} ${VERTEX_IMAGE_DIGEST} ${METERING_IMAGE_DIGEST} ${RDS_EGRESS_CIDR} ${KUBE_DNS_SERVICE_IP} ${KUBE_API_SERVICE_IP} ${KUBE_API_ENDPOINT_IP}' \
  <"$TMP_DIR/enmaas-vertex.yaml" >"$TMP_DIR/enmaas-rendered.yaml"
yq -e 'select(.kind == "ConfigMap" and .metadata.name == "praxis-config") | .data."praxis.yaml"' \
  "$TMP_DIR/enmaas-rendered.yaml" >"$TMP_DIR/praxis.yaml"
yq eval '.' "$TMP_DIR/praxis.yaml" >/dev/null
grep -q 'model_policy_check: true' "$TMP_DIR/praxis.yaml"
METERING_MODEL_POLICY_CHECK=false python3 deploy/openshift/render-enmaas-vertex.py \
  "$TMP_DIR/enmaas-kustomized.yaml" \
  deploy/openshift/overlays/enmaas/vertex-fragments \
  >"$TMP_DIR/enmaas-without-model-policy.yaml"
envsubst '${NAMESPACE} ${QWEN_ENDPOINT} ${CB_GLM_ENDPOINT} ${GATEWAY_HOST} ${GATEWAY_URL} ${DASHBOARD_HOST} ${VERTEX_PROJECT} ${VERTEX_IMAGE_DIGEST} ${METERING_IMAGE_DIGEST} ${RDS_EGRESS_CIDR}' \
  <"$TMP_DIR/enmaas-without-model-policy.yaml" >"$TMP_DIR/enmaas-without-model-policy-rendered.yaml"
yq -e 'select(.kind == "ConfigMap" and .metadata.name == "praxis-config") | .data."praxis.yaml"' \
  "$TMP_DIR/enmaas-without-model-policy-rendered.yaml" >"$TMP_DIR/praxis-without-model-policy.yaml"
if grep -q 'model_policy_check:' "$TMP_DIR/praxis-without-model-policy.yaml"; then
  echo "disabled model-policy config must be omitted for old Praxis binaries" >&2
  exit 1
fi
if grep -nE '\$\{[A-Z_][A-Z0-9_]*\}' "$TMP_DIR/enmaas-rendered.yaml"; then
  echo "unresolved manifest variables remain" >&2
  exit 1
fi

echo "== EnMaaS route contract =="
routes="$(yq -r 'select(.kind == "Route") | .metadata.name' "$TMP_DIR/enmaas-rendered.yaml" | sort)"
grep -qx 'ai-gateway' <<<"$routes"
grep -qx 'ai-gateway-chat-completions' <<<"$routes"
grep -qx 'ai-gateway-responses' <<<"$routes"
grep -qx 'ai-gateway-conversations' <<<"$routes"
grep -qx 'ai-gateway-models' <<<"$routes"
grep -qx 'dashboard-welcome' <<<"$routes"
grep -qx 'dashboard-page' <<<"$routes"
grep -qx 'dashboard-api-usage' <<<"$routes"
grep -qx 'dashboard-api-model-policies' <<<"$routes"
! grep -qx 'dashboard' <<<"$routes"
! grep -q 'llm-katan' "$TMP_DIR/enmaas-rendered.yaml"

dashboard_paths="$(yq -r -N 'select(.kind == "Route" and .spec.host == "'"$DASHBOARD_HOST"'") | .spec.path' "$TMP_DIR/enmaas-rendered.yaml")"
while IFS= read -r path; do
  case "$path" in
    /welcome|/login|/logout|/health|/ready|/dashboard|/manager|/admin|/routing|/me|/invite|/whoami|/api/v1/whoami|/api/v1/pricing|/api/v1/dashboard|/api/v1/org|/api/v1/me|/api/v1/admin|/api/v1/usage|/api/v1/model-policies)
      ;;
    *)
      echo "dashboard Route path is not an approved UI path: ${path:-<catch-all>}" >&2
      exit 1
      ;;
  esac
done <<<"$dashboard_paths"

  for path in /api/v1/usage /api/v1/model-policies; do
  yq -e 'select(.kind == "Route" and .spec.host == "'"$DASHBOARD_HOST"'" and .spec.path == "'"$path"'") | select(.spec.tls.termination == "edge" and .spec.tls.insecureEdgeTerminationPolicy == "Redirect")' \
    "$TMP_DIR/enmaas-rendered.yaml" >/dev/null
  done

yq -e 'select(.kind == "NetworkPolicy" and .metadata.name == "enmaas-allow-router-praxis") | .spec.ingress[].ports[] | select(.protocol == "TCP" and .port == 8081)' \
  "$TMP_DIR/enmaas-rendered.yaml" >/dev/null
yq -e 'select(.kind == "NetworkPolicy" and .metadata.name == "enmaas-allow-cnpg-operator") | .spec.ingress[].ports[] | select(.protocol == "TCP" and .port == 8000)' \
  "$TMP_DIR/enmaas-rendered.yaml" >/dev/null

for policy in enmaas-allow-maas-api-rds-egress enmaas-allow-metering-rds-egress; do
  yq -e "select(.kind == \"NetworkPolicy\" and .metadata.name == \"$policy\") | .spec.egress[] | select(.to[]?.ipBlock.cidr == \"$RDS_EGRESS_CIDR\") | .ports[] | select(.protocol == \"TCP\" and .port == 5432)" \
    "$TMP_DIR/enmaas-rendered.yaml" >/dev/null
done

yq -e 'select(.kind == "Deployment" and .metadata.name == "metering-service") | .spec.template.spec.containers[0].env[] | select(.name == "DASHBOARD_USE_ROLLUPS" and .value == "false")' \
  "$TMP_DIR/enmaas-rendered.yaml" >/dev/null

echo "== EnMaaS Vertex contract =="
grep -q 'model_to_provider' "$TMP_DIR/praxis.yaml"
grep -q 'gcp_adc' "$TMP_DIR/praxis.yaml"
grep -q '@sha256:' "$TMP_DIR/enmaas-rendered.yaml"
grep -q 'claude-sonnet-4-5' "$TMP_DIR/praxis.yaml"
grep -q 'beta_allowlist' "$TMP_DIR/praxis.yaml"
grep -q 'internal_auth_file' "$TMP_DIR/praxis.yaml"

echo "== secret-pattern scan =="
if git grep -n -I -E 'BEGIN (RSA|OPENSSH|EC|DSA) PRIVATE KEY|sk-[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_-]{20,}' -- ':!*.lock'; then
  echo "possible credential material found in tracked files" >&2
  exit 1
fi

echo "PR validation passed"
