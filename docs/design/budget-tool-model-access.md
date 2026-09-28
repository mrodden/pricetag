# Budget Tool → Per-User Model Access Design

## Goal

Allow an external AI Budget Tool to restrict a user to an explicit model
allowlist when aggregate spend across systems exceeds policy.

The Budget Tool may observe Gemini, Vertex, PriceTag, and other costs. PriceTag
does not need to own the global spend calculation; it needs a secure,
idempotent control interface for the inference decision.

## Current gap

PriceTag currently supports API-key validation, group/static model access,
per-user token/dollar quota enforcement, and key revocation. It does not
support a durable per-user model allowlist.

## Proposed policy API

```text
PUT    /api/v1/internal/access/users/{subject}/models
GET    /api/v1/internal/access/users/{subject}/models
DELETE /api/v1/internal/access/users/{subject}/models
POST   /api/v1/internal/access/users/{subject}/suspend
POST   /api/v1/internal/access/users/{subject}/resume
```

Example:

```json
{
  "subject": "john-doe",
  "mode": "allowlist",
  "models": ["hosted-model-a", "luna"],
  "reason": "budget-threshold",
  "source": "ai-budget-tool",
  "request_id": "budget-event-123",
  "effective_at": "2026-09-28T12:00:00Z",
  "expires_at": "2026-10-01T00:00:00Z"
}
```

The API must be private and machine-authenticated through workload identity,
mTLS, or OAuth client credentials. It must not use a shared super-admin
browser session.

## Decision precedence

```text
emergency user suspension
  > user-specific model policy
  > group policy
  > tenant policy
  > global model policy
```

Policies match stable public model IDs. Provider prefixes must not leak into
the user-facing contract.

## Runtime requirements

The gateway should not synchronously call the Budget Tool for every request.
The tool writes policy to PriceTag; PriceTag validates, audits, caches, and
publishes the latest last-known-good policy to the gateway.

Required behavior:

- idempotent updates using `request_id`;
- stale-update rejection using effective timestamps;
- bounded cache TTL and reload metrics;
- last-known-good policy during policy-store outages;
- fail-closed behavior for an active suspension;
- automatic expiry and restoration;
- no prompt or response content storage;
- auditable policy changes and rollback.

## Acceptance criteria

- One user can be restricted without affecting peers.
- Allowed models continue working.
- Disallowed models fail before provider routing.
- Propagation is observable and bounded.
- Replayed updates are harmless.
- Provider migrations preserve policy identity.
