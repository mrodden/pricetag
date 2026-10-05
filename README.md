# PriceTag — The Enterprise AI Control Plane

PriceTag is the enterprise AI control plane for safe access, cost governance,
provider portability, and operational accountability.

It provides a self-service LLM gateway platform for OpenShift deployments,
with authenticated inference, hosted-model routing, usage metering, quota
controls, operational dashboards, and a path to transparent provider
migrations.

This repository is the deployment and operations home for the platform.

## Deploy

Start with the [new-cluster deployment how-to](docs/operations/new-cluster-deployment.md).
It is the guarded operator checklist from target selection through acceptance
and teardown. Use the [full OpenShift deployment guide](docs/openshift-deploy-guide.md)
for manifest details, manual installation commands, backups, and recovery.

The deploy script is deliberately guarded. It requires a dedicated
`PRICETAG_KUBECONFIG`, an `EXPECTED_OC_SERVER`, the separately configured
`PROTECTED_OC_SERVER` for the team deployment, and `CONFIRM_DEPLOYMENT=true`.
It aborts before any write if the kubeconfig points at the protected production
server or the server does not match the expected target.

Deployment inputs are environment-specific. Never commit provider keys,
database passwords, session secrets, kubeconfigs, or generated API keys.

The intended profiles are:

- `test`: isolated namespace and disposable storage.
- `enmaas`: isolated practice deployment on the separate EnMaaS cluster.
- `dogfood`: the team deployment profile.
- `ha`: CloudNativePG, backups, restore, and read-replica operations.

The deploy script preserves existing generated Secrets and ConfigMaps. Set
`ROTATE_SECRETS=true` only for an intentional credential rotation; otherwise a
second run reuses the existing database password, session secret, provider
credentials, and object-store configuration. The `enmaas` profile uses AWS
OIDC workload identity for CNPG backups and never creates static AWS/COS keys.

For AWS/ROSA profiles, run `deploy/openshift/provision-aws-backup-target.sh`
before `deploy.sh` to reconcile the private backup bucket and least-privilege
CNPG IAM role.

## Repository Layout

- `deploy/openshift/`: deployment manifests and operational database assets.
- `docs/architecture.md`: how the deployed system behaves — public surface,
  request lifecycle, model/dialect pairings, data, TLS, network posture, and
  the invariants to preserve. Start here before changing anything.
- `docs/`: OpenShift deployment and database runbooks.
- `docs/troubleshooting.md`: symptom-first diagnosis, including the common
  `404`/`400`/empty-content client errors.
- `docs/operations/functional-tests.md`: tiered tests against a deployed
  environment (`tools/functional-test.sh`).
- `docs/operations/new-cluster-deployment.md`: guarded end-to-end checklist for
  bootstrapping and accepting a new OpenShift environment.
- `docs/operations/rds-debug-client.md`: on-demand, read-only psql client for
  production RDS diagnostics.
- `docs/operations/key-concurrency-test.md`: secure 200-key auth/inference
  concurrency ramp and metering-reconciliation procedure.>>>>>>> ade4bf2 (feat(tools): add secure 200-key concurrency harness)
- `docs/operations/image-provenance.md`: image source and release requirements.
- `docs/design/`: forward-looking plans for Budget Tool integration, SSO,
  privacy/location claims, and organization-chart authorization.
- `docs/operations/enmaas-it-reference.md`: current EnMaaS images, routes,
  verified Vertex models, and internal-tool integration APIs.
- `docs/operations/pr-validation.md`: fast, non-mutating Pull Request checks.
- `docs/operations/security-baseline.md`: EnMaaS security controls, evidence,
  exceptions, and open remediation risks.
- `tools/`: deployment-adjacent benchmarks and validation tools.
- `SOURCE-MAP.md`: provenance and explicit exclusions.

The metering service and dashboard live in
[`redhat-et/pricetag-metering`](https://github.com/redhat-et/pricetag-metering).
Gateway, MaaS API, and model-server source remain in their upstream projects;
this repository consumes approved image or commit references rather than
vendoring their histories.

## Security

All deployment secrets are supplied at runtime through OpenShift Secrets or
environment variables. Public contributions must pass the repository's full
history secret scan before publication.

## License

Apache License 2.0. See `NOTICE` for third-party attributions.
