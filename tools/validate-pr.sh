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
export GATEWAY_HOST=ai-gateway-enmaas.apps.ci.example.com
export GATEWAY_URL=https://$GATEWAY_HOST
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
envsubst '${NAMESPACE} ${QWEN_ENDPOINT} ${CB_GLM_ENDPOINT} ${GATEWAY_HOST} ${GATEWAY_URL} ${VERTEX_PROJECT} ${VERTEX_IMAGE_TAG}' \
  <"$TMP_DIR/enmaas-vertex.yaml" >"$TMP_DIR/enmaas-rendered.yaml"
yq -e 'select(.kind == "ConfigMap" and .metadata.name == "praxis-config") | .data."praxis.yaml"' \
  "$TMP_DIR/enmaas-rendered.yaml" >"$TMP_DIR/praxis.yaml"
yq eval '.' "$TMP_DIR/praxis.yaml" >/dev/null
if grep -nE '\$\{[A-Z_][A-Z0-9_]*\}' "$TMP_DIR/enmaas-rendered.yaml"; then
  echo "unresolved manifest variables remain" >&2
  exit 1
fi

echo "== EnMaaS route contract =="
routes="$(yq -r 'select(.kind == "Route") | .metadata.name' "$TMP_DIR/enmaas-rendered.yaml" | sort)"
grep -qx 'ai-gateway' <<<"$routes"
grep -qx 'ai-gateway-models' <<<"$routes"
grep -qx 'dashboard' <<<"$routes"
! grep -Eq 'ai-gateway-(chat-completions|responses|conversations)' <<<"$routes"
! grep -q 'llm-katan' "$TMP_DIR/enmaas-rendered.yaml"

echo "== EnMaaS Vertex contract =="
grep -q 'model_to_provider' "$TMP_DIR/praxis.yaml"
grep -q 'gcp_adc' "$TMP_DIR/praxis.yaml"
grep -q 'practice-ci' "$TMP_DIR/enmaas-rendered.yaml"
grep -q 'claude-sonnet-4-5' "$TMP_DIR/praxis.yaml"
grep -q 'beta_allowlist' "$TMP_DIR/praxis.yaml"

echo "== secret-pattern scan =="
if git grep -n -I -E 'BEGIN (RSA|OPENSSH|EC|DSA) PRIVATE KEY|sk-[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_-]{20,}' -- ':!*.lock'; then
  echo "possible credential material found in tracked files" >&2
  exit 1
fi

echo "PR validation passed"
