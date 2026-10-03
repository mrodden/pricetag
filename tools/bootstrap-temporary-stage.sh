#!/usr/bin/env bash
# Bootstrap only the isolated temporary stage namespace. This script never
# installs operators, CRDs, RBAC outside enmaas-stage, or application workloads.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$SCRIPT_DIR/../deploy/openshift/stage-bootstrap/00-namespace.yaml"
EXPECTED_STAGE_SERVER="${EXPECTED_STAGE_SERVER:-https://api.models-arch-ocp.ijxt.p3.openshiftapps.com:443}"
PRODUCTION_SERVER="https://api.enmaas-prod.187f.p3.openshiftapps.com:443"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

actual_server="$(oc whoami --show-server 2>/dev/null)" || die "not logged in to OpenShift"
[[ "$actual_server" == "$EXPECTED_STAGE_SERVER" ]] || \
  die "connected to $actual_server, expected temporary stage $EXPECTED_STAGE_SERVER"
[[ "$actual_server" != "$PRODUCTION_SERVER" ]] || die "refusing to mutate production"
[[ "${CONFIRM_TEMPORARY_STAGE:-false}" == true ]] || \
  die "set CONFIRM_TEMPORARY_STAGE=true after verifying the target cluster"

# This bootstrap is intentionally namespaced except for the Namespace itself.
# Reject future edits that smuggle another cluster-scoped kind into the file.
bad_kinds="$(yq ea -r 'select(.kind != "Namespace" and .metadata.namespace != "enmaas-stage") | .kind + "/" + .metadata.name' "$MANIFEST")"
[[ -z "$bad_kinds" ]] || die "manifest contains resources outside enmaas-stage: $bad_kinds"

echo "==> server-side validation"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
yq ea 'select(.kind == "Namespace")' "$MANIFEST" >"$tmp_dir/namespace.yaml"
yq ea 'select(.kind != "Namespace")' "$MANIFEST" >"$tmp_dir/namespaced.yaml"
oc apply --dry-run=client -f "$MANIFEST" >/dev/null
oc apply --dry-run=server -f "$tmp_dir/namespace.yaml" >/dev/null

# The API server cannot simulate creating a Namespace and validating objects
# inside it in one multi-document dry-run. Create the already validated empty
# Namespace first, then server-validate every namespaced guardrail before any
# workload can be admitted there.
oc apply -f "$tmp_dir/namespace.yaml"
oc apply --dry-run=server -f "$tmp_dir/namespaced.yaml" >/dev/null
echo "==> diff"
oc diff -f "$MANIFEST" || diff_status=$?
[[ "${diff_status:-0}" == 0 || "${diff_status:-0}" == 1 ]] || die "oc diff failed"
echo "==> apply isolated stage bootstrap"
oc apply -f "$MANIFEST"
echo "==> verify"
oc -n enmaas-stage get resourcequota,limitrange,networkpolicy
