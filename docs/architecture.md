# EnMaaS architecture

How the deployed system fits together, as it runs in production today. The
[deployment guide](openshift-deploy-guide.md) covers how to install it; this
covers how it behaves once it is running, and the invariants worth knowing
before you change anything.

End-user documentation — getting a key, client configuration, pricing — lives
on the welcome page the dashboard serves, not here.

## Public surface

Production exposes exactly two hostnames, both edge-terminated TLS:

| Host | Serves | Backed by |
|------|--------|-----------|
| `api.enmaas.devshift.net` | the inference API | praxis |
| `dashboard.enmaas.devshift.net` | PriceTag dashboard, partner APIs | metering-service |

One inference hostname carries every dialect; the **path** selects which
Praxis listener handles the request. Each path is its own OpenShift Route:

| Path | Dialect |
|------|---------|
| `/v1/messages` | Anthropic Messages |
| `/v1/chat/completions`, `/v1/responses`, `/v1/conversations` | OpenAI |
| `/v1/models` | both — the envelope is chosen by request headers |

Older `*.apps.rosa.<cluster>` hostnames still resolve through compatibility
Routes (`ai-gateway-legacy-*`) so existing clients keep working. They are
retired behind `RETIRE_LEGACY_GATEWAY_HOSTS`.

### Route claims

OpenShift admits **one Route per host+path**. A duplicate claim is silently
rejected and the path keeps being served by whichever Route won. Two Routes
can therefore both look healthy in `oc get routes` while one is dead.

Check with:

```bash
oc -n enmaas get routes -o json | \
  python3 -c 'import json,sys; [print(r["metadata"]["name"], c["status"]) \
    for r in json.load(sys.stdin)["items"] \
    for i in r.get("status",{}).get("ingress",[]) \
    for c in i.get("conditions",[]) if c["type"]=="Admitted"]'
```

Anything other than `True` means a claim collision. `tools/functional-test.sh`
asserts this at `smoke` level.

## Request lifecycle

1. **Edge** — the Route terminates TLS and forwards to the Praxis listener
   for that path.
2. **Authenticate** — Praxis validates the client credential against maas-api
   (`POST /internal/v1/api-keys/validate`, 300 s cache). `x-api-key` for the
   Anthropic dialect, `Authorization: Bearer` for OpenAI.
3. **Pin identity** — `identity_header_guard` strips any client-supplied
   `x-tenant-*` headers first, then Praxis sets them from the validated key.
   Client-asserted identity is never trusted.
4. **Authorise the model** — `model_access` applies per-group allow/deny lists
   from the key's group; metering-service can additionally hold a per-user
   allowlist.
5. **Route the model** — `model_to_header` promotes the body's `model` field to
   `X-Model`; the router picks the upstream cluster (Vertex, OpenAI,
   curvebender, or a self-hosted backend).
6. **Meter** — `external_metering` reports the request and streamed usage to
   metering-service. This is **fail-open**: metering outages never block
   inference, so a metering incident shows up as missing rows, not errors.
7. **Inject credentials** — the client credential is stripped and the real
   provider key injected; the load balancer sends it upstream with the correct
   `Host`/SNI.

## Models and dialects

A model is only reachable on the dialect that routes it, with that dialect's
parameter spelling. The combinations are not interchangeable:

| Model family | Endpoint | Token parameter | Wrong combination |
|---|---|---|---|
| `claude-*` (Vertex) | `/v1/messages` only | `max_tokens` | `404` on chat/completions — it falls through to the OpenAI upstream, which has no Claude model |
| `gpt-5.x` (OpenAI) | `/v1/chat/completions` | `max_completion_tokens` | `400 Unsupported parameter: 'max_tokens'` |
| `rits/zai-org/glm-5-3` (hosted, free) | either | `max_tokens` | — |
| `gpt-5.3-codex` | Responses only | — | fails on chat/completions |

**Reasoning models** spend the output budget on reasoning before emitting
anything. GLM 5.3 at `max_tokens: 16` returns `content: null` with
`finish_reason: "length"` and the whole budget in `reasoning_content` — a
successful, billed call that looks like a failure. Budget accordingly.

> **Known defect:** the OpenAI-format `/v1/models` catalog currently advertises
> Claude models that `404` on chat/completions, and hides the GPT and GLM
> models that work — see
> [#47](https://github.com/redhat-et/pricetag/issues/47). Until it is fixed,
> model discovery is unreliable for OpenAI-dialect clients; the working model
> IDs must be configured explicitly.

## Data

| Store | Production | dogfood / test |
|---|---|---|
| Usage events, keys | AWS RDS PostgreSQL, Multi-AZ, enforced TLS (`rds.force_ssl`) | in-cluster CloudNativePG (`postgres:16-alpine`) |

metering-service holds two DSNs: a read/write one for ingestion and a
read-only one (`READ_DATABASE_URL`, a distinct DB role) used by dashboard
reads and the Prometheus exporter. maas-api reads its DSN from a Secret via
the Kubernetes API rather than env vars.

Because production uses RDS, database egress is explicit: NetworkPolicies
allow `5432` to the RDS CIDR only from the workloads that need it. A missing
egress rule presents as a connection timeout at startup, not a config error.

## TLS and DNS

Certificates are issued by **cert-manager** from Let's Encrypt over HTTP-01
(DNS-01 is unavailable — the zone lives in a different AWS account), and
renewed automatically at 60 days of a 90-day lifetime.

Routes reference the resulting Secrets through `spec.tls.externalCertificate`,
which requires an RBAC grant letting the ingress router read those Secrets in
the namespace. Both the ClusterIssuer and the Certificates are declared in
git; nothing here is created by hand.

## Network posture

The namespace runs **default-deny** for ingress and egress. Everything that
works does so because an explicit policy allows it:

- DNS egress to `openshift-dns` — the one most easily forgotten; a wrong
  selector here makes pods crashloop at startup on DNS resolution
- router → praxis and router → dashboard ingress
- `enmaas-monitoring` → scrape ports
- workload → RDS CIDR on `5432`
- metering-service → Kubernetes API

A new component therefore needs its policy added in the same change, or it
will fail in ways that look unrelated to networking.

## Observability

Prometheus, Alertmanager and Grafana run in `enmaas-monitoring`, each behind
an nginx basic-auth sidecar. Prometheus federates node-level metrics from
platform monitoring and scrapes the workloads directly.

Praxis exposes metrics on its admin listener (`9901`). Binding that listener
beyond loopback is a recorded exception with compensating controls — ingress
restricted to monitoring namespaces under default-deny, and never exposed
through a Route. See
[security-baseline.md](operations/security-baseline.md).

A `postgres_exporter` reports RDS health using the read-only role.

## Environments

| Profile | Cluster | Database | Hostnames |
|---|---|---|---|
| `enmaas` | production ROSA | AWS RDS | `*.enmaas.devshift.net` |
| `dogfood` | sandbox | CloudNativePG | `*.apps.<cluster>` |
| `test` | stage | CloudNativePG | `*.apps.<cluster>` |

The overlays share a base; per-environment differences are parameters, not
forks. Verify a target before deploying with
`tools/validate-live-enmaas.sh`, and verify behaviour after with
`tools/functional-test.sh`.

## Invariants worth preserving

- **One Route per host+path.** Duplicates are rejected silently.
- **Metering is fail-open.** It must never become a dependency of serving.
- **Client identity is never trusted.** Inbound `x-tenant-*` headers are
  stripped before Praxis sets its own.
- **Images are digest-pinned.** Tags are not deployed; the static baseline
  enforces this.
- **Rolling updates use `maxUnavailable: 0`, `maxSurge: 1`.** A bad config
  fails to become Ready instead of taking traffic down — which is what makes
  a bad rollout recoverable.
- **Everything live is in git.** Cluster state applied by hand drifts back on
  the next deploy and is lost.
