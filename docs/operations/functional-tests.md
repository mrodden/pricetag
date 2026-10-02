# Functional tests

`tools/functional-test.sh` exercises a *deployed* EnMaaS environment from the
outside in. It complements, and does not replace, the static gates:

| Tool | Scope | Needs a cluster |
|------|-------|-----------------|
| `tools/validate-pr.sh` | renders and contracts in the repo | no |
| `tools/security-static-validate.sh` | security baseline in the repo | no |
| `tools/validate-live-enmaas.sh` | pre-deploy readiness of a target | yes |
| `tools/functional-test.sh` | behaviour of a running environment | optional |

## Levels

Levels are cumulative: each one runs everything below it.

| Level | What it adds | Credential | Cost |
|-------|--------------|-----------|------|
| `smoke` | DNS, TLS validity and SAN, HTTP→HTTPS, health endpoints, the unauthenticated deny wall, forged-identity headers, and — with a kubeconfig — Route admission and workload readiness | none | free |
| `auth` | a valid key is accepted, an invalid one refused, both catalog dialects return the right envelope, the key is never echoed back | `PRICETAG_KEY` | free |
| `inference` | one tiny completion per (model, endpoint) pair | `PRICETAG_KEY` | tokens |
| `full` | streaming, error shapes, concurrency, metering proof | `PRICETAG_KEY` | tokens |

Anything whose credential is missing **SKIPs**; it never fails. That is what
lets the same suite run unchanged in CI and from an operator's laptop.

## Targets

The suite is environment-agnostic. Use a known profile:

```bash
./tools/functional-test.sh --target enmaas              # smoke, production
./tools/functional-test.sh --target dogfood --level auth
```

or point it anywhere by host:

```bash
GATEWAY_HOST=gw.example.com DASHBOARD_HOST=dash.example.com \
  ./tools/functional-test.sh --level smoke
```

`dogfood` and `test` resolve their hosts from Routes via `oc`, so they need a
login; `enmaas` has its public hostnames built in and needs nothing.

## Production safety

`smoke` and `auth` are read-only and safe against production at any time.
From `inference` up the suite sends real model traffic, so against a
production target it refuses to run without an explicit acknowledgement:

```bash
./tools/functional-test.sh --target enmaas --level inference --confirm-prod
```

Keys are passed to `curl` through a `0600` config file — never on the command
line, never logged. Requests are capped at 16 output tokens.

## Model matrix

Inference levels exercise one free/hosted model plus one from each external
provider, so a provider-specific outage cannot hide behind a working peer:

| Role | Default | Override |
|------|---------|----------|
| free / hosted | `rits/zai-org/glm-5-3` | `MODEL_FREE` |
| Anthropic | `claude-haiku-4-5` | `MODEL_ANTHROPIC` |
| OpenAI | `gpt-5.4` | `MODEL_OPENAI` |

Override them for an environment whose catalog differs:

```bash
MODEL_OPENAI=gpt-5.6-luna ./tools/functional-test.sh --target dogfood --level inference
```

### Dialect and parameter compatibility

A model is only callable on the dialect that routes it, using that dialect's
parameter spelling. Getting this wrong produces errors that look like gateway
faults but are client errors — the suite encodes the correct combinations:

| Model | Endpoint | Token parameter | Wrong combination gives |
|-------|----------|-----------------|-------------------------|
| `claude-*` | `/v1/messages` only | `max_tokens` | `404` on `/v1/chat/completions` — the request falls through to the OpenAI upstream, which has no Claude model |
| `gpt-5.x` | `/v1/chat/completions` | `max_completion_tokens` | `400 Unsupported parameter: 'max_tokens'` |
| `rits/zai-org/glm-5-3` | either | `max_tokens` | — |
| `gpt-5.3-codex` | Responses only | — | fails a Chat Completions check |

### Reasoning models and the output cap

`MAX_OUT` (default 64) must clear the reasoning budget. GLM 5.3 is a reasoning
model: at `max_tokens: 16` the entire budget is spent on `reasoning_content`
and the response comes back with `content: null` and
`finish_reason: "length"` — a working call that looks like a failure.

The success criterion is therefore "the model produced output and tokens were
billed": non-empty `content` **or** `reasoning_content` (Anthropic: `text` or
`thinking`), plus a non-zero completion/output token count.

### Known failures

Three checks fail against production today, all from one defect
([#47](https://github.com/redhat-et/pricetag/issues/47)): the OpenAI-format
catalog advertises Claude models that `404` on `/v1/chat/completions` while
hiding the GPT and GLM models that work. The scheduled job runs `smoke`,
which does not touch the catalog, so it stays green; `auth` and higher will
show these three until the catalog filters are deduplicated.

## CI

`.github/workflows/functional-tests.yml` runs the suite:

- **scheduled**, four times a day against production at `smoke` level, so an
  expired certificate, a dropped Route claim or a broken auth wall surfaces
  within hours instead of at the next deploy;
- **on demand** (`workflow_dispatch`) with a target, a level, optional host
  overrides, and a `confirm_prod` checkbox that gates model traffic.

Add `PRICETAG_KEY` and `PARTNER_TOKEN` as repository secrets to enable the
authenticated levels. Without them the authenticated checks SKIP and the
scheduled smoke run still does its job. CI has no cluster access, so the
kubeconfig-dependent checks always SKIP there.

## Why these checks

Most assertions exist because the corresponding failure already happened:

- **Route admission** — duplicate host+path claims silently reject a Route and
  leave the path served by whichever one won the claim.
- **Forged identity headers** — a Route once trusted `X-MaaS-Username`
  outright.
- **Partner API deny wall** — those endpoints were briefly designed to carry no
  application-level authentication at all.
- **TLS expiry window** — certificates are renewed at 60 days of a 90-day
  lifetime; alerting at 14 days remaining leaves room to react.
- **Unauthenticated deny** — the property that matters is "never a 2xx". A
  redirect to `/login` and a `404` on a bare prefix are both legitimate
  denials, so the suite accepts them and verifies the redirect target rather
  than demanding a literal `401` everywhere.
