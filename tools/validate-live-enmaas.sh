#!/usr/bin/env bash
# Read-only EnMaaS preflight. This script never applies, patches, deletes,
# restarts, scales, or builds anything.
set -euo pipefail

: "${PRICETAG_KUBECONFIG:?Set PRICETAG_KUBECONFIG to the target kubeconfig}"
: "${EXPECTED_OC_SERVER:?Set EXPECTED_OC_SERVER to the target API server}"
: "${PROTECTED_OC_SERVER:?Set PROTECTED_OC_SERVER to the protected production API server}"
export KUBECONFIG="$PRICETAG_KUBECONFIG"

die() { printf 'LIVE PREFLIGHT FAILED: %s\n' "$*" >&2; exit 1; }
server="$(oc whoami --show-server)"
[[ "$server" == "$EXPECTED_OC_SERVER" ]] || die "connected to $server, expected $EXPECTED_OC_SERVER"
[[ "$server" != "$PROTECTED_OC_SERVER" ]] || die "connected to protected production server"

ns=enmaas
for deployment in maas-api metering-service praxis; do
  replicas="$(oc -n "$ns" get deployment "$deployment" -o jsonpath='{.spec.replicas}')"
  ready="$(oc -n "$ns" get deployment "$deployment" -o jsonpath='{.status.readyReplicas}')"
  available="$(oc -n "$ns" get deployment "$deployment" -o jsonpath='{.status.availableReplicas}')"
  [[ "$ready" == "$replicas" && "$available" == "$replicas" ]] || \
    die "$deployment is not fully Ready/Available ($ready/$replicas ready, $available/$replicas available)"
  strategy="$(oc -n "$ns" get deployment "$deployment" -o jsonpath='{.spec.strategy.rollingUpdate.maxUnavailable}/{.spec.strategy.rollingUpdate.maxSurge}')"
  [[ "$strategy" == "0/1" ]] || die "$deployment rolling strategy is $strategy, expected 0/1"
  image="$(oc -n "$ns" get deployment "$deployment" -o jsonpath='{.spec.template.spec.containers[0].image}')"
  [[ "$image" == *@sha256:* ]] || die "$deployment image is not digest pinned"
done

for secret in enmaas-public-tls api-enmaas-tls dashboard-enmaas-tls metering-internal-auth \
  metering-partner-api metering-user-management-api; do
  oc -n "$ns" get secret "$secret" >/dev/null || die "required Secret missing: $secret"
done
for secret in enmaas-public-tls; do
  [[ "$(oc -n "$ns" get secret "$secret" -o jsonpath='{.type}')" == kubernetes.io/tls ]] || \
    die "$secret is not kubernetes.io/tls"
  oc auth can-i --as=system:serviceaccount:openshift-ingress:router \
    get "secret/$secret" -n "$ns" | grep -qx yes || die "router cannot read $secret"
done

for policy in enmaas-default-deny enmaas-allow-dns enmaas-allow-monitoring-scrape \
  enmaas-allow-metering-rds-egress enmaas-allow-metering-kube-api \
  enmaas-allow-router-dashboard enmaas-allow-router-praxis; do
  oc -n "$ns" get networkpolicy "$policy" >/dev/null || die "NetworkPolicy missing: $policy"
done

printf 'LIVE PREFLIGHT PASSED: target=%s namespace=%s\n' "$server" "$ns"
