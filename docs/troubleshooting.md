# PriceTag Troubleshooting

This guide is symptom-first. Run read-only probes first. Do not restart,
scale, or patch the team deployment while diagnosing it.

## Requests Return 401

Check the listener dialect and header:

- The single `ai-gateway` hostname dispatches `/v1/messages` to the Anthropic pipeline (`x-api-key`) and `/v1/chat/completions` plus `/v1/responses` to the OpenAI-compatible pipeline (`Authorization: Bearer ...`).
- Both dialects use `/v1/models`; include `anthropic-version: 2023-06-01` for the Anthropic model-list envelope. OpenAI-compatible clients receive the OpenAI envelope when that header is absent.
- Confirm the key exists and is active in MaaS.
- Check `maas-api` logs and the gateway logs for validation failures.

An unauthenticated request should return `401` on every protected route.

## Requests Return 403

Check the model name and the user's MaaS group membership. Inspect the
`model_access` configuration and verify the requested model is present in the
appropriate allowlist.

## Requests Return 404 "The model ... does not exist"

Almost always a dialect mismatch rather than a missing model. A model is only
reachable on the dialect that routes it:

- `claude-*` are **Messages-only**. Sent to `/v1/chat/completions` they fall
  through to the OpenAI upstream, which genuinely has no such model — so the
  404 text is OpenAI's, not ours. Use `/v1/messages` with `x-api-key` and
  `anthropic-version: 2023-06-01`.
- `gpt-5.3-codex` is Responses-only and 404s on chat/completions.

Confirm the pairing in [architecture.md](architecture.md#models-and-dialects)
before investigating routing.

## Requests Return 400 "Unsupported parameter: 'max_tokens'"

`gpt-5.x` models require `max_completion_tokens`. The older `max_tokens`
spelling is rejected by the upstream. Other families still use `max_tokens`,
so a client that hardcodes one spelling will work with some models and fail
with others.

## Response Has `content: null` and `finish_reason: "length"`

Not an error. Reasoning models spend the output budget on reasoning before
emitting any visible content; if the budget runs out first, `content` is
`null` and the tokens appear under `reasoning_content` /
`completion_tokens_details.reasoning_tokens`. GLM 5.3 does this at
`max_tokens: 16`.

Raise the output cap. The call succeeded and was billed, so metering rows
will exist for it.

## A Model Is Missing From `/v1/models`

The catalog and the router are configured separately, so a model can be
routable but unadvertised, or advertised but dead.

Known defect [#47](https://github.com/redhat-et/pricetag/issues/47): the
OpenAI-format catalog advertises Claude models that 404 on chat/completions
while hiding the GPT and GLM models that work. Until it is fixed, configure
working model IDs explicitly instead of relying on discovery.

Confirm what a key can actually see:

```bash
curl -sS https://api.enmaas.devshift.net/v1/models \
  -H "Authorization: Bearer $PRICETAG_KEY" | python3 -m json.tool
```

## A Path Returns 503 Or Serves Stale Behaviour

Likely a Route claim collision. OpenShift admits one Route per host+path and
silently rejects duplicates, so two Routes can both appear healthy while only
one serves. List any that are not admitted:

```bash
oc -n enmaas get routes -o json | \
  python3 -c 'import json,sys; [print(r["metadata"]["name"], c["status"]) \
    for r in json.load(sys.stdin)["items"] \
    for i in r.get("status",{}).get("ingress",[]) \
    for c in i.get("conditions",[]) if c["type"]=="Admitted" and c["status"]!="True"]'
```

Deleting the duplicate frees the claim and the surviving Route is admitted
within seconds. `tools/functional-test.sh --level smoke` asserts this.

## Pods Crashloop Immediately After A Network Policy Change

The namespace is default-deny. The usual cause is DNS: if the egress policy
does not select `openshift-dns` correctly, pods fail to resolve any hostname
and exit during startup — typically while connecting to the database, which
makes it look like a database problem.

Check the pod's last termination message and whether DNS egress is allowed
before investigating the database.

## Monitoring Targets All Down At Once

A new default-deny or egress policy that omits the monitoring ingress rule
takes out every scrape simultaneously. A single failed target is a workload
problem; all of them failing together is a policy problem.

## Dashboard Has No Usage

Check the complete path:

1. Gateway logs for the `external_metering` response.
2. Metering service logs for CloudEvent ingestion.
3. The `usage_events` table in the primary CNPG service.
4. The model name and provider recorded in the event.
5. `model_pricing` for a matching pricing row.

The usage database is the metering log of record. A successful model response
without a corresponding `usage_events` row is a deployment defect.

## Dashboard Numbers Are Slow or Inconsistent

Inspect `/api/v1/admin/rollups` and the metering service logs. The dashboard
should fall back to raw reads when rollup parity is unhealthy. Do not repair
the rollup by deleting ledger data. Rebuild derived data from `usage_events`
using the documented CNPG operations.

## Database Problems

Check the CNPG cluster and instances:

```bash
oc get cluster aigateway-pg -n "$NS"
oc get pods -n "$NS" -l cnpg.io/cluster=aigateway-pg
oc describe cluster aigateway-pg -n "$NS"
```

The production profile uses three CNPG instances and the RWO storage class
selected for the environment. A primary failure should be handled by CNPG;
do not manually promote a pod.

## Backup or Restore Problems

Check the `ScheduledBackup`, the `cnpg-backup-cos` Secret, the COS endpoint,
the pinned SigV4 region, and the CNPG operator logs. A backup object existing
is not enough; perform a restore drill in a separate namespace and verify the
restored ledger counts.

Never run schema-wipe or repair jobs against the live team namespace without
explicit approval and a verified backup.

## Latency or Streaming Problems

Use `tools/praxis-overhead.py` for paired direct-upstream versus gateway
measurements. Report medians for warm and cold connections rather than a
single request. Check gateway pod logs, OpenShift router logs, and provider
connection resets separately.

For streaming failures, verify the route timeout, edge TLS route, provider
SNI, and the client's HTTP protocol. Do not infer a gateway regression from a
single cold request.

## WebSocket Upgrade Behavior

Probe the exact client upgrade shape with HTTP/1.1 `Upgrade` and
`Connection` headers. The `reject_upgrade` filter is intended to prevent
unmetered opaque tunnels, but a configured filter is not proof that the live
transport detects every client shape. Record the request shape, status, and
whether a usage row was written.

The acceptance test must reproduce the original client transport, not only a
synthetic curl variant.

## Welcome-Client Validation

Run `tools/prove-welcome-clients.sh` against a test or shadow deployment for
the supported Claude Code, Codex, and OpenCode paths. A successful request and
a non-zero metering row are both required.
