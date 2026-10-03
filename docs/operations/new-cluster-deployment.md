# Deploy EnMaaS to a new OpenShift cluster

This is the operator checklist for taking an empty OpenShift cluster to a
working EnMaaS/PriceTag environment. It tells you which decisions must be made,
which inputs must already exist, how to use the guarded deployment, and what
evidence proves the result works.

For manifest details and manual installation commands, use the
[full deployment reference](../openshift-deploy-guide.md). Read
[architecture.md](../architecture.md) before changing the request path or
security boundaries.

## 1. Choose the environment contract

Do not start by running `deploy.sh`. Record these decisions first:

| Decision | Required answer |
|---|---|
| OpenShift API server | Exact URL; this becomes `EXPECTED_OC_SERVER` |
| Production API server | Exact URL to protect with `PROTECTED_OC_SERVER` |
| Profile and namespace | One of the supported pairs below |
| Database | In-cluster CNPG or pre-provisioned RDS |
| Image source | Immutable digests available in the target cluster/registry |
| Route hosts | Cluster apps-domain or approved public DNS |
| Provider access | Stage-specific keys/endpoints and spending controls |
| Owners and expiry | Who operates it and, for temporary environments, when it is removed |

Supported profile/namespace pairs are enforced by the script:

| Profile | Namespace | Typical use |
|---|---|---|
| `dogfood` | `ai-gateway-dogfood` | Team environment |
| `test` | `pricetag-test` | Disposable integration environment |
| `enmaas` | `enmaas` | EnMaaS deployment with production-specific routing and controls |

Do not repurpose a profile by overriding its namespace; the script refuses
that combination because Routes, RBAC and image references are profile-specific.

## 2. Establish the safety boundary

Use a dedicated kubeconfig containing only the target cluster. Never deploy
from a kubeconfig whose current context can silently change to production.

```bash
install -m 0600 /secure/download/new-cluster.kubeconfig ~/.kube/enmaas-target
export PRICETAG_KUBECONFIG=$HOME/.kube/enmaas-target
export KUBECONFIG=$PRICETAG_KUBECONFIG

export EXPECTED_OC_SERVER=https://api.<new-cluster>:6443
export PROTECTED_OC_SERVER=https://api.<production-cluster>:443

oc whoami
test "$(oc whoami --show-server)" = "$EXPECTED_OC_SERVER"
test "$EXPECTED_OC_SERVER" != "$PROTECTED_OC_SERVER"
```

Capture a baseline before any mutation:

```bash
oc get clusterversion
oc get nodes
oc get storageclass
oc get ingress.config.openshift.io cluster -o jsonpath='{.spec.domain}{"\n"}'
oc get ns
```

## 3. Verify prerequisites

Required operator workstation tools:

```bash
for tool in oc kubectl yq envsubst openssl python3; do
  command -v "$tool" || exit 1
done
```

Required cluster capabilities:

- OpenShift 4.22 is the tested target.
- Cluster-admin for first installation (CRDs and CNPG are cluster-scoped).
- A default or explicitly selected RWO storage class.
- Router/Route support and an apps domain.
- Egress to required providers and object storage.
- Sufficient quota for three application workloads and PostgreSQL.

Check the intended storage class explicitly:

```bash
export STORAGE_CLASS=gp3-csi       # example; choose the target's class
oc get storageclass "$STORAGE_CLASS"
```

### Database choice

**CNPG** is the normal disposable/test choice. It requires an object-store
backup target in the current deployment path. Supply environment-specific
bucket, endpoint, region and credentials/role; never reuse a production
backup bucket.

**RDS** is supported only by the `enmaas` profile. Provision it before the
deployment, require TLS in every DSN, and restrict the approved egress CIDR.
The deployment script validates the DSN hostname, port and `sslmode` before it
writes application Secrets.

## 4. Prepare immutable images

A fresh cluster cannot pull another OpenShift cluster's internal registry
URLs. Before deploying, ensure these images exist in the target registry:

- `maas-api`
- `metering-service`
- `praxis-ai`
- `llm-katan` when the selected profile includes it

Pin source commits and record the resulting image digests. The `enmaas`
deployment path can build Praxis and metering-service from explicit source
SHAs using `build-praxis-et.sh` and `build-metering-et.sh`; it does **not**
automatically make MaaS API portable to a fresh cluster. `dogfood` and `test`
overlays assume their target ImageStreams/tags already exist.

Do not:

- copy mutable `latest` tags between environments;
- point a new cluster at `image-registry.../<production-namespace>/...`;
- build an unreviewed branch because it is convenient;
- deploy until every workload resolves to an immutable digest.

Record provenance per [image-provenance.md](image-provenance.md).

## 5. Prepare deployment inputs

Keep values in a mode-0600 file outside git, then source it into the operator
shell. Do not put plaintext keys directly in command history.

Minimum common inputs:

```bash
export PROFILE=test                    # example
export NAMESPACE=pricetag-test
export DATABASE_BACKEND=cnpg
export STORAGE_CLASS=gp3-csi

export ADMIN_USERS='operator@example.com'
export SUPERADMIN_USERS='operator@example.com'
export MAAS_SECURE=false
export MAAS_DEBUG_MODE=false

export QWEN_ENDPOINT=<stage-hostname>
export CB_GLM_ENDPOINT=<stage-hostname>

export COS_BUCKET=<stage-bucket>
export COS_ENDPOINT=<object-store-endpoint>
export COS_REGION=<region>
export COS_ACCESS_KEY_ID=<stage-only-key>
export COS_SECRET_ACCESS_KEY=<stage-only-secret>

export ANTHROPIC_API_KEY=<stage-key>
export OPENAI_API_KEY=<stage-key-or-approved-placeholder>
export LITELLM_API_KEY=<stage-key>
export CB_LITELLM_API_KEY=<stage-key>
```

For EnMaaS/Vertex builds, also provide pinned `PRAXIS_SOURCE_SHA`,
`METERING_SOURCE_SHA`, `VERTEX_PROJECT`, and the service-account JSON only when
creating or intentionally rotating `vertex-sa-key`. For RDS, provide the
approved host, DSNs and egress CIDR described in `deploy.sh`.

Generated database/session/partner credentials are preserved on reruns.
Never set `ROTATE_SECRETS=true` during an ordinary deployment.

## 6. Validate the repository and rendered intent

Run both non-mutating repository gates:

```bash
./tools/validate-pr.sh
./tools/security-static-validate.sh
```

Render the selected overlay and inspect object scope, hosts and images:

```bash
kubectl kustomize "deploy/openshift/overlays/$PROFILE" > /tmp/pricetag-render.yaml

yq ea '[.kind, .metadata.namespace, .metadata.name] | @tsv' \
  /tmp/pricetag-render.yaml
yq ea 'select(.kind == "Deployment") |
  [.metadata.name, .spec.template.spec.containers[].image] | @tsv' \
  /tmp/pricetag-render.yaml
yq ea 'select(.kind == "Route") | [.metadata.name, .spec.host] | @tsv' \
  /tmp/pricetag-render.yaml
```

Stop if the render contains:

- another environment's namespace or hostname;
- a production RDS endpoint/Secret reference;
- mutable or missing images;
- unresolved `${...}` placeholders after the environment-specific render;
- an unexpected cluster-scoped resource.

`PREFLIGHT_ONLY=true` is currently implemented only for `PROFILE=enmaas` with
RDS. For other profiles, the static render above is mandatory; do not assume
the normal script's later `oc diff` is mutation-free, because installation has
already begun by that point.

## 7. Run the guarded deployment

Only after reviewing the server, render and inputs:

```bash
export CONFIRM_DEPLOYMENT=true
./deploy/openshift/deploy.sh
```

The script aborts before writes when:

- the kubeconfig is missing;
- the API server differs from `EXPECTED_OC_SERVER`;
- the target equals `PROTECTED_OC_SERVER`;
- profile and namespace do not match;
- required database/provider/storage inputs are missing or invalid.

On a first install it may reconcile cluster-scoped MaaS CRDs and the CNPG
operator. Announce this before running on a shared cluster.

## 8. Acceptance checks

### Workloads and database

```bash
oc -n "$NAMESPACE" get pods,deploy,svc,pvc
oc -n "$NAMESPACE" rollout status deploy/maas-api --timeout=5m
oc -n "$NAMESPACE" rollout status deploy/metering-service --timeout=5m
oc -n "$NAMESPACE" rollout status deploy/praxis --timeout=5m

if [[ "$DATABASE_BACKEND" == cnpg ]]; then
  oc -n "$NAMESPACE" get cluster.postgresql.cnpg.io aigateway-pg
  oc -n "$NAMESPACE" get endpoints aigateway-pg-rw
fi
```

### Routes and authentication

Every Route must be admitted; merely existing is not enough:

```bash
oc -n "$NAMESPACE" get routes -o json | python3 -c '
import json,sys
for route in json.load(sys.stdin)["items"]:
    conditions=[c for i in route.get("status",{}).get("ingress",[])
                for c in i.get("conditions",[]) if c["type"]=="Admitted"]
    print(route["metadata"]["name"], conditions[0]["status"] if conditions else "missing")'
```

Then verify externally:

```bash
curl -fsS "https://$DASHBOARD_HOST/health"
curl -fsS "https://$DASHBOARD_HOST/ready"
test "$(curl -sk -o /dev/null -w '%{http_code}' "https://$GATEWAY_HOST/v1/models")" = 401
test "$(curl -sk -o /dev/null -w '%{http_code}' "https://$DASHBOARD_HOST/api/v1/users")" = 401
```

### Functional suite

```bash
GATEWAY_HOST="$GATEWAY_HOST" DASHBOARD_HOST="$DASHBOARD_HOST" \
  ./tools/functional-test.sh --level smoke

# With a stage test key:
PRICETAG_KEY=<stage-key> \
GATEWAY_HOST="$GATEWAY_HOST" DASHBOARD_HOST="$DASHBOARD_HOST" \
  ./tools/functional-test.sh --level auth
```

Do not run inference/full levels against a paid environment until cost limits
and the test identity are explicitly approved.

## 9. Monitoring

Application deployment and monitoring are separate. Install the monitoring
stack from `redhat-et/open-models/deployments/enmaas/monitoring` or integrate
the workload into the target cluster's supported monitoring stack.

Minimum acceptance:

- every expected target is scraped per pod, not through a Service VIP;
- alert delivery is tested end-to-end;
- database health is represented by the database actually in use;
- dashboards resolve their datasource through Grafana, not only via direct
  Prometheus queries.

## 10. Rerun, rollback and teardown

An ordinary rerun must preserve Secrets. Review `oc diff`; do not rotate
credentials as part of troubleshooting.

For application rollback, restore the prior approved image digest and rerun
the workload rollout. A database rollback is a separate operation governed by
the backup/restore runbook; never point applications at an old database while
writers are still active on the new one.

For temporary environments:

1. record an expiry date at creation;
2. remove Routes first;
3. confirm no users or integrations still target them;
4. delete the namespace;
5. confirm PVCs and cloud backup objects are removed or intentionally retained;
6. review cluster-scoped CRDs/operators before removal because another
   namespace may now depend on them.

## Final go/no-go checklist

- [ ] Exact target server verified; production protected.
- [ ] Profile/namespace contract recorded.
- [ ] Immutable images and source provenance recorded.
- [ ] Database and backup target are environment-specific.
- [ ] No production credentials or endpoints appear in the render.
- [ ] Static/security gates pass.
- [ ] Render reviewed; all placeholders resolved.
- [ ] Workloads Ready with safe rolling strategies.
- [ ] Routes admitted and authentication fails closed.
- [ ] Functional smoke passes.
- [ ] Monitoring and alert delivery verified.
- [ ] Owner, rollback path and teardown date documented.
