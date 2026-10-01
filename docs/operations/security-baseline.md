# EnMaaS Security Baseline

This document records the security controls, evidence, exceptions, and open
risks for the isolated EnMaaS PriceTag deployment.

It is an operational control record, not a claim of product certification. A
control is only marked **PASS** when there is current code, manifest, or live
evidence supporting it.

**Environment:** EnMaaS OpenShift cluster, namespace `enmaas`  
**Scope:** PriceTag standalone deployment and its hosted-model egress  
**Production:** not in scope and not modified by this work  
**Tracking:** [PriceTag #13](https://github.com/redhat-et/pricetag/issues/13),
[security baseline PR #14](https://github.com/redhat-et/pricetag/pull/14)

## Security objectives

1. Prevent unauthenticated access to inference, quota, key, and administrative
   operations.
2. Keep provider credentials, database credentials, API keys, and service
   account keys out of source, images, ConfigMaps, logs, and evidence.
3. Restrict pod-to-pod and outbound network access to required flows.
4. Run application workloads with least privilege and hardened pod settings.
5. Make every deployed artifact traceable to a source revision and immutable
   image digest.
6. Preserve availability while applying controls through staged rollout,
   health checks, and rollback.

## Current control matrix

| Control | Status | Evidence / remaining work |
|---|---|---|
| Production deployment guard | **PASS** | `deploy/openshift/deploy.sh` requires a dedicated kubeconfig, expected server, protected server check, and explicit confirmation. |
| External inference API-key validation | **PASS** | Praxis validates keys through the internal MaaS API and strips client credentials before provider forwarding. |
| Vertex service-account secret delivery | **PASS** | Key is mounted from the `vertex-sa-key` OpenShift Secret; it is not in images or repositories. |
| Immutable Praxis provenance | **PASS** | ET source `c74dc146`; deployed image digest is recorded in the deployment evidence. |
| PR regression validation | **PASS** | Fast non-mutating workflow completes in seconds and does not access clusters or secrets. |
| Static security baseline | **IN PROGRESS** | PR #14 is being updated for RDS egress, RDS target guards, rollup fail-safe behavior, and route-path assertions. |
| Default-deny NetworkPolicies | **LIVE, CORRECTED** | EnMaaS policies include narrow TCP/5432 egress to the approved RDS CIDR. The first live rollout blocked DNS, the Kubernetes API, CNPG operator status, the router→Praxis port and Prometheus scraping; every allow rule found on the cluster is now recorded in `overlays/enmaas/network-policy.yaml` and asserted by the validators. A default-deny change must ship with its allow inventory verified against the target cluster, not after. |
| Public-host TLS in git | **IMPLEMENTED IN PR** | Every Route on `api.enmaas.devshift.net` and `dashboard.enmaas.devshift.net` references the host certificate Secret (`externalCertificate`); the router SA may read exactly those two Secrets; Secrets are never committed. Removes the dependency on a hand-created Route set holding TLS for the host. |
| Pod security contexts | **IMPLEMENTED IN PR** | Praxis, MaaS API, and metering hardening is rendered; live rollout validation remains required. |
| Praxis admin endpoint isolation | **LIVE, WITH EXCEPTION** | Default render binds the admin listener (`/metrics`, `/ready`, `/healthy` only) to loopback. This silently stopped Prometheus scraping Praxis when it shipped. EnMaaS may opt in with `PRAXIS_PUBLIC_ADMIN=true`, which sets `insecure_options.allow_public_admin` and binds `0.0.0.0:9901`; the baseline refuses that render unless `enmaas-default-deny` plus 9901 ingress limited to the monitoring namespaces are present and no Route targets the port. Owner: EnMaaS platform. Review when Praxis offers a dedicated metrics listener. |
| Digest-pinned application images | **IMPLEMENTED IN PR** | EnMaaS overlay records current image digests; update procedure must be documented for every image change. |
| Public quota endpoint boundary | **IMPLEMENTED IN PR** | Dashboard route-path assertions exclude `/api/v1/customers/...`; live unauthenticated and internal authenticated probes remain required. |
| Usage-event ingestion boundary | **IMPLEMENTED IN PR** | Dashboard route-path assertions exclude `/api/v1/events`; live unauthenticated and internal authenticated probes remain required. |
| Budget Tool machine authentication | **OPEN** | Dedicated private service identity and scoped quota API are not yet implemented. |
| Atlas key-minting boundary | **OPEN** | Key minting exists behind dashboard authorization; a private service-to-service contract is still required. |
| CSRF protection | **OPEN** | Session cookies are Secure, HttpOnly, and SameSite, but explicit CSRF protection for state-changing APIs requires review. |
| Workload identity for Vertex | **OPEN** | Current pilot uses a file-backed service-account Secret; workload identity/federation is the target production direction. |
| Supply-chain SBOM/signature policy | **OPEN** | Source and digests are recorded, but automated SBOM, vulnerability, and signature enforcement is not yet complete. |
| Database TLS | **OPEN** | Current internal application DSNs use `sslmode=disable`; review whether cluster-internal TLS is required for the target threat model. |

## Public and private boundaries

### Public

The public EnMaaS routes are:

- `/v1/messages` — authenticated inference;
- `/v1/models` — model catalog;
- dashboard host — browser UI and dashboard APIs.

The dashboard Route must not expose internal machine-to-machine APIs without
their own authentication. In particular, entitlement and usage-event APIs are
not browser-facing APIs.

### Private

The following must remain private ClusterIP/service-to-service flows:

- Praxis → MaaS API key validation;
- Praxis → metering entitlement checks;
- Praxis → metering usage events;
- MaaS API/metering → PostgreSQL;
- CNPG → backup object storage;
- Praxis → approved hosted-model egress.

## Secret handling requirements

- Secrets are supplied at deployment time, never committed.
- Secret values must not appear in ConfigMaps, image layers, logs, Events, or
  CI artifacts.
- API keys are shown only once at mint time and must be stored in a dedicated
  secret manager by consuming tools.
- Vertex service-account material is temporary pilot infrastructure and should
  be replaced by workload identity for a production deployment.
- Unused provider credential Secrets must be removed or rotated after the
  rollback-retention window ends.

## Validation strategy

### Per Pull Request

The fast validation job is required to remain non-mutating and under the
ten-minute budget. It covers rendering, route contracts, deployment guards,
syntax, digest expectations, and secret-pattern scans.

The static security baseline is a separate required security workstream while
the known findings are being closed. It must fail loudly and list all findings
rather than silently allowing a partial baseline.

### Scheduled or pre-release

Slower validation belongs in an isolated or disposable OpenShift environment:

- unauthenticated and authenticated API probes;
- quota and key authorization;
- NetworkPolicy enforcement;
- Praxis admin-port reachability;
- RBAC and ServiceAccount token checks;
- Secret/log/evidence scans;
- Vertex inference and metering;
- backup restore and database integrity;
- upgrade, rollback, and recovery behavior.

Mutating probes must use disposable identities and test resources. Production
credentials and production clusters are never used by CI.

## Risk acceptance and exceptions

Every temporary exception should record:

- the affected control;
- why it is temporarily required;
- the environment and scope;
- an owner;
- an expiry/review date;
- compensating controls;
- the remediation issue or PR.

The current public internal-API exposure is not considered an acceptable
production exception. It remains an open remediation item.

## Incident and recovery expectations

Security incidents or suspected credential exposure require:

1. revoke or rotate the affected provider/API/service-account credential;
2. preserve sanitized logs and deployment/image provenance;
3. identify affected users, models, and time window;
4. validate metering and quota integrity;
5. redeploy from a known-good immutable image/configuration;
6. record the incident and follow-up control change.
