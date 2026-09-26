# EnMaaS IT Integration Reference

This document is the IT-facing reference for the isolated EnMaaS PriceTag
environment.

**Last verified:** 2026-09-25  
**Environment:** EnMaaS OpenShift cluster, namespace `enmaas`  
**Production impact:** none; production is not a deployment target for this
profile.

## Current operating mode

EnMaaS is currently running in **Vertex-only mode**:

```text
Client → OpenShift Route → Praxis → Google Vertex AI Anthropic models
                         ├→ MaaS API (API-key validation)
                         └→ Metering service (quota and usage)
```

The AI Gateway Controller, MaaS Controller, IPP, Kuadrant, Authorino, and
KServe are not deployed in this environment. Direct OpenAI, direct Anthropic,
Qwen, and GLM inference routes are disabled. Their configuration and Secrets
are retained only to preserve rollback capability.

## Container images

| Component | Deployed image/digest | Source | Containerfile/Dockerfile bases |
|---|---|---|---|
| Praxis AI | `enmaas/praxis-ai:practice-c74dc146`  \
`sha256:66207f02fc8190359923bb8b24b10ff6090cc4b353caea90d06672611763ffb9` | `redhat-et/praxis-ai@c74dc146` | Builder: `rust:1.98-alpine3.24`; runtime: `alpine:3.24` |
| MaaS API | `enmaas/maas-api:standalone-1238aafa`  \
`sha256:bbf5b77a3194ea477f236128d2f1499ac8b89957b0798047d1f97c311a069a97` | `opendatahub-io/models-as-a-service/maas-api` | Builder: `registry.access.redhat.com/ubi9/go-toolset:1.26`; runtime: `registry.access.redhat.com/ubi9/ubi-minimal:latest` |
| Metering/dashboard | `enmaas/metering-service:practice-05e9d104`  \
`sha256:05e9d104d251287c000ff577842b56b26054aa2157a20a26cbee434a25ed2993` | `noyitz/ai-gateway-metering-service` | Builder: `golang:1.25-alpine`; runtime: `registry.access.redhat.com/ubi9/ubi-minimal:9.5` |
| CNPG operator | `ghcr.io/cloudnative-pg/cloudnative-pg:1.30.0` | CloudNativePG | Published upstream image |
| PostgreSQL | `ghcr.io/cloudnative-pg/postgresql:16.12` | CloudNativePG | Published upstream image |

The dashboard is embedded in the metering service; it has no separate image.
Hosted model servers are external and are not containers in EnMaaS.

## Public routes

### Inference

| URL | Backend | API and consumers |
|---|---|---|
| `https://ai-gateway-enmaas.apps.rosa.enmaas-prod.187f.p3.openshiftapps.com/v1/messages` | Praxis `unified` port | Anthropic Messages-compatible inference API; Claude Code and Anthropic-compatible clients |
| Same host, `/v1/models` | Praxis `unified` port | Vertex-hosted model catalog and client discovery |

The inference API uses an EnMaaS API key. Model selection is transparent to
clients: the public model ID is mapped internally to the Vertex publisher
model ID.

### Dashboard and administration

```text
https://dashboard-enmaas.apps.rosa.enmaas-prod.187f.p3.openshiftapps.com/
```

This route serves the authenticated dashboard, usage views, key management,
quota management, provider/model administration, and operational status APIs.

The following inference routes are intentionally not active in Vertex-only
mode:

```text
/v1/chat/completions
/v1/responses
/v1/conversations
```

## Private service routes

These are ClusterIP services and are not intended for public access:

| Service | Consumer | Purpose |
|---|---|---|
| `maas-api.enmaas.svc:8080` | Praxis and metering service | API-key validation and MaaS key operations |
| `metering-service.enmaas.svc:8080` | Praxis and dashboard clients | Entitlements, usage events, quota checks, dashboard APIs |
| `praxis.enmaas.svc:8084` | OpenShift Route | Unified inference listener |
| `praxis.enmaas.svc:9901` | Kubernetes probes/operators | Praxis health/admin endpoint; private only |
| `aigateway-pg-rw.enmaas.svc:5432` | MaaS API and metering service | PostgreSQL primary connection |
| `aigateway-pg-ro.enmaas.svc:5432` | Read/reporting paths | PostgreSQL read-only connection |

Vertex egress is outbound HTTPS to:

```text
aiplatform.googleapis.com:443
```

The Google service-account JSON is mounted through the OpenShift Secret
`vertex-sa-key`; it is not stored in an image or repository.

## Verified Vertex-hosted models

Each model below was tested against Vertex with the EnMaaS service account and
then through the EnMaaS gateway with a bounded request:

```text
claude-sonnet-4-5
claude-haiku-4-5
claude-opus-4-5
claude-opus-4-6
claude-sonnet-4-6
claude-opus-4-7
claude-opus-4-8
claude-opus-5
claude-opus-5-5
```

Unavailable for this project/account at verification time:

```text
claude-sonnet-5  — Vertex returned 404/not available
claude-fable-5   — requires Anthropic data sharing
claude-fable-5-1 — requires Anthropic data sharing
```

The catalog exposes only the verified models. Adding future models requires
verifying Vertex access, quota, and provider terms before adding their mapping
and catalog entry.

## AI Budget Tool integration

The Budget Tool needs a **private, authenticated service-to-service
integration**. It should not use browser session cookies or an unauthenticated
public endpoint.

### Current quota APIs

| Capability | API |
|---|---|
| Read an entitlement/quota decision for a user | `GET /api/v1/customers/{username}?model=<model>` |
| Read the current caller's quota | `GET /api/v1/me/quota` |
| Read global quota policy | `GET /api/v1/admin/quota/policy` |
| Update global quota policy | `PATCH /api/v1/admin/quota/policy` |
| List per-user/group overrides | `GET /api/v1/admin/quota/overrides` |
| Add or update a user/group quota | `PUT /api/v1/admin/quota/overrides` |
| Delete an override | `DELETE /api/v1/admin/quota/overrides?scope=user&principal=<id>` |
| Read quota denials | `GET /api/v1/admin/quota/denials` |

An override body is:

```json
{
  "scope": "user",
  "principal": "user-slug",
  "monthly_usd": 100
}
```

Administrative quota APIs require super-admin authorization.

### Stopping a user

There is currently no dedicated `suspend-user` API. The current operational
mechanism is API-key revocation:

```text
DELETE /api/v1/admin/keys/{key-id}
```

A future Budget Tool integration should preferably add an explicit suspended
state rather than using quota changes as a substitute for account suspension.

### Important security note

`GET /api/v1/customers/{username}` is currently a machine-to-machine
entitlement endpoint used by Praxis. It must be treated as private and should
be protected by service identity, mTLS, or an equivalent internal auth layer
before an external tool is allowed to call it.

## Atlas key-minting integration

The current metering service provides key-management operations through:

```text
POST   /api/v1/admin/keys
GET    /api/v1/admin/keys
DELETE /api/v1/admin/keys/{key-id}
```

Key creation accepts a username, group, and key name and returns the plaintext
API key once. Atlas must use a private authenticated service-to-service route,
store the key in a secret manager, and never write the plaintext key to logs or
ordinary application storage.

Direct MaaS API key endpoints exist internally as well, but the metering-service
wrapper is the preferred integration boundary because it applies the PriceTag
user/group scope and audit behavior.

## Future hosted-provider expansion

The public contract should remain the same `/v1/messages` gateway route while
model-to-provider mapping remains internal. If direct Anthropic, OpenAI, or
other hosted providers are re-enabled, the environment will additionally need:

- provider-specific egress allowlists;
- TLS/SNI configuration;
- provider credential Secrets;
- model catalog and pricing entries;
- provider-specific quota and usage attribution;
- explicit model-to-provider mappings.

The current environment intentionally does not expose those providers.

## Operational ownership

- OpenShift Routes, Services, Deployments, Secrets, and CNPG resources are
  managed by the PriceTag deployment profile.
- Provider credentials and the Vertex service account are runtime Secrets.
- PostgreSQL is internal only; it has no public Route.
- Production is not a target of this profile.
- The deployment is guarded by `PRICETAG_KUBECONFIG`, expected-server checks,
  protected-server checks, and `CONFIRM_DEPLOYMENT=true`.
