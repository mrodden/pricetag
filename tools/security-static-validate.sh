#!/usr/bin/env bash
set -uo pipefail

# Static security baseline. This script intentionally reports every known
# baseline failure in one run. It does not contact a cluster or mutate files.

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
export QWEN_ENDPOINT=qwen.ci.example.com
export CB_GLM_ENDPOINT=glm.ci.example.com
export RDS_EGRESS_CIDR=192.0.2.1/32
export METERING_MODEL_POLICY_CHECK=true

cd "$ROOT_DIR"
failures=()

fail() {
  failures+=("$1")
}

check_true() {
  local description=$1
  shift
  if ! "$@"; then
    fail "$description"
  fi
}

echo "== render EnMaaS manifests =="
if ! kubectl kustomize deploy/openshift/overlays/enmaas >"$TMP_DIR/enmaas-kustomized.yaml"; then
  fail "EnMaaS Kustomize build failed"
else
  if ! python3 deploy/openshift/render-enmaas-vertex.py \
      "$TMP_DIR/enmaas-kustomized.yaml" \
      deploy/openshift/overlays/enmaas/vertex-fragments \
      >"$TMP_DIR/enmaas-vertex.yaml"; then
    fail "EnMaaS Vertex fragment rendering failed"
  else
envsubst '${NAMESPACE} ${QWEN_ENDPOINT} ${CB_GLM_ENDPOINT} ${GATEWAY_HOST} ${GATEWAY_URL} ${DASHBOARD_HOST} ${VERTEX_PROJECT} ${VERTEX_IMAGE_DIGEST} ${METERING_IMAGE_DIGEST} ${RDS_EGRESS_CIDR}' \
      <"$TMP_DIR/enmaas-vertex.yaml" >"$TMP_DIR/enmaas-rendered.yaml"
    yq -e 'select(.kind == "ConfigMap" and .metadata.name == "praxis-config") | .data."praxis.yaml"' \
      "$TMP_DIR/enmaas-rendered.yaml" >"$TMP_DIR/praxis.yaml" || fail "Praxis ConfigMap data is missing"
  fi
fi

echo "== deployment safety baseline =="
if [[ -f "$TMP_DIR/enmaas-rendered.yaml" ]]; then
  network_policy_count="$(yq eval-all '[select(.kind == "NetworkPolicy")] | length' "$TMP_DIR/enmaas-rendered.yaml")"
  [[ "$network_policy_count" -gt 0 ]] || fail "EnMaaS has no NetworkPolicy resources"

  if grep -q 'allow_public_admin: true' "$TMP_DIR/praxis.yaml"; then
    fail "Praxis enables insecure_options.allow_public_admin"
  fi
  grep -q 'internal_auth_file' "$TMP_DIR/praxis.yaml" || \
    fail "Praxis metering calls have no internal authentication file configured"

  for deployment in praxis maas-api metering-service; do
    for expression in \
      '.spec.template.spec.securityContext.runAsNonRoot == true' \
      '.spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation == false' \
      '.spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem == true' \
      '((.spec.template.spec.containers[0].securityContext.capabilities.drop // []) | contains(["ALL"])) == true' \
      '.spec.template.spec.containers[0].securityContext.seccompProfile.type == "RuntimeDefault"'; do
      if ! yq -e "select(.kind == \"Deployment\" and .metadata.name == \"$deployment\") | $expression" \
          "$TMP_DIR/enmaas-rendered.yaml" >/dev/null 2>&1; then
        fail "$deployment does not satisfy security context requirement: $expression"
      fi
    done
    token_requirement='false'
    [[ "$deployment" == "maas-api" ]] && token_requirement='true'
    if ! yq -e "select(.kind == \"Deployment\" and .metadata.name == \"$deployment\") | .spec.template.spec.automountServiceAccountToken == $token_requirement" \
        "$TMP_DIR/enmaas-rendered.yaml" >/dev/null 2>&1; then
      fail "$deployment has incorrect ServiceAccount token automount policy (expected $token_requirement)"
    fi
  done

  if yq -e 'select(.kind == "Service" and .metadata.name == "praxis") | .spec.ports[] | select(.port == 9901)' \
      "$TMP_DIR/enmaas-rendered.yaml" >/dev/null 2>&1; then
    fail "Praxis admin port 9901 is exposed by the Service"
  fi

  while IFS= read -r image; do
    [[ "$image" == "---" ]] && continue
    if [[ "$image" != *@sha256:* ]]; then
      fail "application image is not digest-pinned: $image"
    fi
  done < <(yq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[].image' "$TMP_DIR/enmaas-rendered.yaml")

  dashboard_paths="$(yq -r -N 'select(.kind == "Route" and .spec.host == "'"$DASHBOARD_HOST"'") | .spec.path' "$TMP_DIR/enmaas-rendered.yaml")"
  while IFS= read -r path; do
    case "$path" in
      /welcome|/login|/logout|/health|/ready|/dashboard|/manager|/admin|/routing|/me|/invite|/whoami|/api/v1/whoami|/api/v1/pricing|/api/v1/dashboard|/api/v1/org|/api/v1/me|/api/v1/admin|/api/v1/usage|/api/v1/model-policies)
        ;;
      *)
        fail "dashboard Route path is not an approved UI path: ${path:-<catch-all>}"
        ;;
    esac
  done <<<"$dashboard_paths"

  for secret_env in USAGE_REPORT_API_SECRET MODEL_POLICY_API_SECRET; do
    if ! yq -e "select(.kind == \"Deployment\" and .metadata.name == \"metering-service\") | .spec.template.spec.containers[0].env[] | select(.name == \"$secret_env\" and .valueFrom.secretKeyRef.name == \"metering-partner-api\")" \
      "$TMP_DIR/enmaas-rendered.yaml" >/dev/null 2>&1; then
      fail "metering-service $secret_env must come from metering-partner-api Secret"
    fi
  done

  if grep -Eq -- '--from-literal=(usage-report|model-policy)=' deploy/openshift/deploy.sh; then
    fail "partner bearer tokens must not be passed in process arguments"
  fi

  for route in dashboard-api-usage dashboard-api-model-policies; do
    if ! yq -e "select(.kind == \"Route\" and .metadata.name == \"$route\") | select(.spec.tls.termination == \"edge\" and .spec.tls.insecureEdgeTerminationPolicy == \"Redirect\")" \
      "$TMP_DIR/enmaas-rendered.yaml" >/dev/null 2>&1; then
      fail "$route must use edge TLS and redirect insecure HTTP"
    fi
  done

  for policy in enmaas-allow-maas-api-rds-egress enmaas-allow-metering-rds-egress; do
    if ! yq -e "select(.kind == \"NetworkPolicy\" and .metadata.name == \"$policy\") | .spec.egress[] | select(.to[]?.ipBlock.cidr == \"$RDS_EGRESS_CIDR\") | .ports[] | select(.protocol == \"TCP\" and .port == 5432)" \
      "$TMP_DIR/enmaas-rendered.yaml" >/dev/null 2>&1; then
      fail "$policy does not allow the configured RDS CIDR on TCP/5432"
    fi
  done

  if ! yq -e 'select(.kind == "Deployment" and .metadata.name == "metering-service") | .spec.template.spec.containers[0].env[] | select(.name == "DASHBOARD_USE_ROLLUPS" and .value == "false")' \
    "$TMP_DIR/enmaas-rendered.yaml" >/dev/null 2>&1; then
    fail "metering-service must keep DASHBOARD_USE_ROLLUPS=false until the freshness fail-safe is fixed"
  fi
fi

echo "== deployment guard baseline =="
grep -q 'PRICETAG_KUBECONFIG' deploy/openshift/deploy.sh || fail "deployment lacks dedicated kubeconfig guard"
grep -q 'EXPECTED_OC_SERVER' deploy/openshift/deploy.sh || fail "deployment lacks expected-server guard"
grep -q 'PROTECTED_OC_SERVER' deploy/openshift/deploy.sh || fail "deployment lacks protected-server guard"
grep -q 'RDS_EXPECTED_HOST' deploy/openshift/deploy.sh || fail "deployment lacks RDS host guard"
grep -q 'RDS_EGRESS_CIDR' deploy/openshift/deploy.sh || fail "deployment lacks RDS egress configuration"
grep -q 'CONFIRM_DEPLOYMENT' deploy/openshift/deploy.sh || fail "deployment lacks explicit confirmation guard"

echo
if ((${#failures[@]} > 0)); then
  echo "SECURITY BASELINE FAILED (${#failures[@]} findings):" >&2
  printf ' - %s\n' "${failures[@]}" >&2
  exit 1
fi

echo "SECURITY BASELINE PASSED"
