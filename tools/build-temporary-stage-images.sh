#!/usr/bin/env bash
# Build pinned EnMaaS images only on the temporary models-arch stage cluster.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST_DIR="$SCRIPT_DIR/../deploy/openshift/stage-bootstrap"
EXPECTED_SERVER="https://api.models-arch-ocp.ijxt.p3.openshiftapps.com:443"
PRODUCTION_SERVER="https://api.enmaas-prod.187f.p3.openshiftapps.com:443"
NS=enmaas-stage

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
actual_server="$(oc whoami --show-server 2>/dev/null)" || die "not logged in"
[[ "$actual_server" == "$EXPECTED_SERVER" ]] || die "connected to $actual_server, expected $EXPECTED_SERVER"
[[ "$actual_server" != "$PRODUCTION_SERVER" ]] || die "refusing production"
[[ "${CONFIRM_STAGE_IMAGE_BUILDS:-false}" == true ]] || die "set CONFIRM_STAGE_IMAGE_BUILDS=true"
oc get namespace "$NS" >/dev/null || die "$NS does not exist"

echo "==> validate/apply build egress and pinned BuildConfigs"
oc apply --dry-run=server -f "$MANIFEST_DIR/10-build-egress.yaml" >/dev/null
oc apply --dry-run=server -f "$MANIFEST_DIR/20-image-builds.yaml" >/dev/null
oc apply -f "$MANIFEST_DIR/10-build-egress.yaml"
oc apply -f "$MANIFEST_DIR/20-image-builds.yaml"

for build in enmaas-stage-maas-api enmaas-stage-metering enmaas-stage-praxis; do
  echo "==> build $build"
  oc -n "$NS" start-build "bc/$build" --follow --wait
done

maas_ref="$(oc -n "$NS" get istag maas-api:stage-1238aafa -o jsonpath='{.image.dockerImageReference}')"
metering_ref="$(oc -n "$NS" get istag metering-service:stage-1995f188 -o jsonpath='{.image.dockerImageReference}')"
praxis_ref="$(oc -n "$NS" get istag praxis-ai:stage-ae9821f8 -o jsonpath='{.image.dockerImageReference}')"
for ref in "$maas_ref" "$metering_ref" "$praxis_ref"; do
  [[ "$ref" == *@sha256:* ]] || die "image is not digest-pinned: $ref"
done

oc -n "$NS" create configmap enmaas-stage-images \
  --from-literal=MAAS_API_IMAGE="$maas_ref" \
  --from-literal=METERING_IMAGE="$metering_ref" \
  --from-literal=PRAXIS_IMAGE="$praxis_ref" \
  --dry-run=client -o yaml | oc apply -f -

echo "==> immutable stage images"
oc -n "$NS" get configmap enmaas-stage-images -o jsonpath='{.data}'
echo
