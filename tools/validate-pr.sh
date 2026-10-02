#!/usr/bin/env bash
set -euo pipefail

# Fast, non-mutating Pull Request validation. This intentionally does not log
# into OpenShift, build images, contact providers, or use deployment Secrets.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
# Most checks are bare yq/grep tests; name the failing one instead of exiting silently.
trap 'echo "validate-pr: check failed at ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR
# Neither `! cmd` (exempt from errexit in every bash) nor a false `[[ ]]`
# (ignored by macOS bash 3.2) reliably stops the script. Negative and equality
# checks go through these helpers so a failure is loud on every platform.
refute() {
  if "$@" >/dev/null 2>&1; then
    echo "validate-pr: expected failure but succeeded: $*" >&2
    exit 1
  fi
}
assert_eq() {
  if [[ "$1" != "$2" ]]; then
    echo "validate-pr: $3: expected '$2', got '$1'" >&2
    exit 1
  fi
}

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
[[ -x tools/validate-live-enmaas.sh ]] || {
  echo "tools/validate-live-enmaas.sh must be executable" >&2
  exit 1
}

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
grep -q 'pricetag.io/praxis-config-checksum' deploy/openshift/deploy.sh
grep -q 'PREFLIGHT_ONLY' deploy/openshift/deploy.sh

echo "== Kustomize profiles =="
for profile in test dogfood enmaas; do
  kubectl kustomize "deploy/openshift/overlays/$profile" >"$TMP_DIR/$profile.yaml"
  yq eval '.' "$TMP_DIR/$profile.yaml" >/dev/null
done

echo "== EnMaaS rendered Praxis configuration =="
kubectl kustomize deploy/openshift/overlays/enmaas >"$TMP_DIR/enmaas-kustomized.yaml"
# Pin the render to the documented default: operators export
# PRAXIS_PUBLIC_ADMIN=true for the live deployment, and the "default render"
# assertions below must not inherit that from the environment.
PRAXIS_PUBLIC_ADMIN=false python3 deploy/openshift/render-enmaas-vertex.py \
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
# Default render keeps the admin listener on loopback; the opt-in render binds
# it on the pod network together with the flag Praxis requires for that.
grep -q 'address: "127.0.0.1:9901"' "$TMP_DIR/praxis.yaml"
refute grep -q 'allow_public_admin' "$TMP_DIR/praxis.yaml"
PRAXIS_PUBLIC_ADMIN=true python3 deploy/openshift/render-enmaas-vertex.py \
  "$TMP_DIR/enmaas-kustomized.yaml" \
  deploy/openshift/overlays/enmaas/vertex-fragments \
  | yq -e 'select(.kind == "ConfigMap" and .metadata.name == "praxis-config") | .data."praxis.yaml"' \
  >"$TMP_DIR/praxis-public-admin.yaml"
yq eval '.' "$TMP_DIR/praxis-public-admin.yaml" >/dev/null
assert_eq "$(yq -r '.admin.address' "$TMP_DIR/praxis-public-admin.yaml")" "0.0.0.0:9901" "public-admin bind"
assert_eq "$(yq -r '.insecure_options.allow_public_admin' "$TMP_DIR/praxis-public-admin.yaml")" "true" "allow_public_admin flag"
assert_eq "$(yq -r '.insecure_options | length' "$TMP_DIR/praxis-public-admin.yaml")" "1" "only one insecure option set"
yq -e 'select(.kind == "Service" and .metadata.name == "praxis") | .spec.ports[] | select(.name == "metrics" and .port == 9901)' \
  "$TMP_DIR/enmaas-rendered.yaml" >/dev/null
grep -q 'PRAXIS_PUBLIC_ADMIN' deploy/openshift/deploy.sh
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
grep -qx 'dashboard-api-users' <<<"$routes"
grep -qx 'dashboard-api-models' <<<"$routes"
refute grep -qx 'dashboard' <<<"$routes"
# The benchmark model is dogfood-only: no llm-katan workload may render for
# EnMaaS. The Praxis benchmark pipeline may still name the cluster; that dead
# listener is separate from deploying an llm-katan workload.
refute yq -e 'select((.kind == "Deployment" or .kind == "Service" or .kind == "Route") and .metadata.name == "llm-katan")' "$TMP_DIR/enmaas-rendered.yaml"

dashboard_paths="$(yq -r -N 'select(.kind == "Route" and .spec.host == "'"$DASHBOARD_HOST"'") | .spec.path' "$TMP_DIR/enmaas-rendered.yaml")"
while IFS= read -r path; do
  case "$path" in
    /welcome|/login|/logout|/health|/ready|/dashboard|/manager|/admin|/routing|/me|/invite|/whoami|/api/v1/whoami|/api/v1/pricing|/api/v1/dashboard|/api/v1/org|/api/v1/me|/api/v1/admin|/api/v1/usage|/api/v1/model-policies|/api/v1/users|/api/v1/models)
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

# Every Route on a public host carries that host's certificate, so no single
# Route (or Route set) is the hidden holder of TLS for the host.
if yq -e 'select(.kind == "Route" and .spec.host == "'"$GATEWAY_HOST"'" and .spec.tls.externalCertificate.name != "api-enmaas-tls")' \
  "$TMP_DIR/enmaas-rendered.yaml" >/dev/null 2>&1; then
  echo "a gateway Route does not reference api-enmaas-tls" >&2
  exit 1
fi
if yq -e 'select(.kind == "Route" and .spec.host == "'"$DASHBOARD_HOST"'" and .spec.tls.externalCertificate.name != "dashboard-enmaas-tls")' \
  "$TMP_DIR/enmaas-rendered.yaml" >/dev/null 2>&1; then
  echo "a dashboard Route does not reference dashboard-enmaas-tls" >&2
  exit 1
fi
for tls_secret in api-enmaas-tls dashboard-enmaas-tls; do
  yq -e 'select(.kind == "Role" and .metadata.name == "router-read-'"$tls_secret"'") | .rules[] | select(.resources[] == "secrets" and .resourceNames[] == "'"$tls_secret"'")' \
    "$TMP_DIR/enmaas-rendered.yaml" >/dev/null
  yq -e 'select(.kind == "RoleBinding" and .metadata.name == "router-read-'"$tls_secret"'") | .subjects[] | select(.kind == "ServiceAccount" and .name == "router" and .namespace == "openshift-ingress")' \
    "$TMP_DIR/enmaas-rendered.yaml" >/dev/null
done
refute grep -qE 'kind: Secret' deploy/openshift/overlays/enmaas/*.yaml

# Compatibility Routes for the legacy gateway host render standalone and never
# touch the canonical host.
LEGACY_GATEWAY_HOST=ai-gateway-enmaas.apps.example.test envsubst '${NAMESPACE} ${LEGACY_GATEWAY_HOST}' \
  < deploy/openshift/overlays/enmaas/legacy-gateway-routes.yaml > "$TMP_DIR/legacy-routes.yaml"
yq eval '.' "$TMP_DIR/legacy-routes.yaml" >/dev/null
refute grep -q '\${' "$TMP_DIR/legacy-routes.yaml"
refute yq -e 'select(.kind == "Route" and .spec.host == "'"$GATEWAY_HOST"'")' "$TMP_DIR/legacy-routes.yaml"
assert_eq "$(yq -r -N 'select(.kind == "Route") | .metadata.labels."pricetag.io/legacy-gateway-host"' "$TMP_DIR/legacy-routes.yaml" | sort -u)" "true" "legacy Routes carry the retirement label"
assert_eq "$(yq -r -N 'select(.kind == "Route") | .spec.host' "$TMP_DIR/legacy-routes.yaml" | sort -u)" "ai-gateway-enmaas.apps.example.test" "legacy Routes use only the legacy host"
grep -q 'RETIRE_LEGACY_GATEWAY_HOSTS' deploy/openshift/deploy.sh
grep -q 'oc diff -f' deploy/openshift/deploy.sh

yq -e 'select(.kind == "NetworkPolicy" and .metadata.name == "enmaas-allow-router-praxis") | .spec.ingress[].ports[] | select(.protocol == "TCP" and .port == 8081)' \
  "$TMP_DIR/enmaas-rendered.yaml" >/dev/null
yq -e 'select(.kind == "NetworkPolicy" and .metadata.name == "enmaas-allow-cnpg-operator") | .spec.ingress[].ports[] | select(.protocol == "TCP" and .port == 8000)' \
  "$TMP_DIR/enmaas-rendered.yaml" >/dev/null
# Prometheus in enmaas-monitoring must be able to scrape; losing this rule
# blanked every dashboard when default-deny first shipped.
for port in 9901 9090 8080 9187; do
  yq -e 'select(.kind == "NetworkPolicy" and .metadata.name == "enmaas-allow-monitoring-scrape") | select(.spec.ingress[].from[].namespaceSelector.matchLabels."kubernetes.io/metadata.name" == "enmaas-monitoring") | .spec.ingress[].ports[] | select(.protocol == "TCP" and .port == '"$port"')' \
    "$TMP_DIR/enmaas-rendered.yaml" >/dev/null
done

for policy in enmaas-allow-maas-api-rds-egress enmaas-allow-metering-rds-egress; do
  yq -e "select(.kind == \"NetworkPolicy\" and .metadata.name == \"$policy\") | .spec.egress[] | select(.to[]?.ipBlock.cidr == \"$RDS_EGRESS_CIDR\") | .ports[] | select(.protocol == \"TCP\" and .port == 5432)" \
    "$TMP_DIR/enmaas-rendered.yaml" >/dev/null
done

yq -e 'select(.kind == "Deployment" and .metadata.name == "metering-service") | .spec.template.spec.containers[0].env[] | select(.name == "DASHBOARD_USE_ROLLUPS" and .value == "false")' \
  "$TMP_DIR/enmaas-rendered.yaml" >/dev/null
for deployment in maas-api metering-service praxis; do
  yq -e "select(.kind == \"Deployment\" and .metadata.name == \"$deployment\") | select(.spec.strategy.type == \"RollingUpdate\" and .spec.strategy.rollingUpdate.maxUnavailable == 0 and .spec.strategy.rollingUpdate.maxSurge == 1)" \
    "$TMP_DIR/enmaas-rendered.yaml" >/dev/null
done

echo "== EnMaaS Vertex contract =="
grep -q 'model_to_provider' "$TMP_DIR/praxis.yaml"
grep -q 'gcp_adc' "$TMP_DIR/praxis.yaml"
grep -q '@sha256:' "$TMP_DIR/enmaas-rendered.yaml"
grep -q 'claude-sonnet-4-5' "$TMP_DIR/praxis.yaml"
grep -q 'beta_allowlist' "$TMP_DIR/praxis.yaml"
grep -q 'internal_auth_file' "$TMP_DIR/praxis.yaml"

echo "== EnMaaS model-catalog hygiene =="
# The base anthropic/OpenAI model_catalog filters still render into the EnMaaS
# ConfigMap alongside the Vertex-only catalog; Metering's /api/v1/models dedups
# across every model_catalog entry. Guard against stale or non-public ids
# leaking back into the EnMaaS-advertised catalog. Dated model ids and the
# octo-eng-only Fable model must not appear.
for stale_id in claude-haiku-4-5-20251001 claude-fable-5; do
  if grep -q "$stale_id" "$TMP_DIR/praxis.yaml"; then
    echo "stale/non-public model id '$stale_id' leaked into the EnMaaS catalog" >&2
    exit 1
  fi
done
if grep -nE 'id: claude-[a-z]+-[0-9.]+-[0-9]{8}' "$TMP_DIR/praxis.yaml"; then
  echo "dated Claude model id must not appear in the EnMaaS catalog" >&2
  exit 1
fi

echo "== secret-pattern scan =="
if git grep -n -I -E 'BEGIN (RSA|OPENSSH|EC|DSA) PRIVATE KEY|sk-[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_-]{20,}' -- ':!*.lock'; then
  echo "possible credential material found in tracked files" >&2
  exit 1
fi

echo "PR validation passed"
