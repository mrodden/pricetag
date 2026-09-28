# SSO Location and Country Claims

## Goal

Use authoritative SSO/identity claims for country or regional policy without
inferring location from IP addresses or collecting prompt content.

## Source of truth

The identity provider should provide a documented claim such as:

```text
country: "US"
region: "NA"
work_country: "DE"
```

Prefer ISO 3166-1 alpha-2 country codes and a documented region mapping. If the
claim is missing, stale, or ambiguous, use `unknown`; never guess from IP,
email domain, or browser locale.

## Privacy requirements

- Store only the minimum location attribute needed for policy.
- Do not store precise location or IP-derived location for this purpose.
- Do not place location in prompts, provider requests, or model context.
- Restrict visibility to authorization and approved aggregate reporting.
- Document retention, correction, and deletion behavior.

## Acceptance criteria

- Claims are validated and normalized at the identity boundary.
- Unknown values never grant broader access.
- Location decisions are auditable as metadata only.
- Tests cover missing, changed, malformed, and conflicting claims.
