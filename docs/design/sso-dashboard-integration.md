# SSO Dashboard Integration Design

## Goal

Replace dashboard API-key login with corporate SSO while preserving API keys
for inference clients, Claude Code, Atlas, automation, and other machine
consumers.

## Recommended protocol

Use OIDC Authorization Code + PKCE:

```text
Browser → corporate IdP → authorization code → PriceTag callback
        → claim/signature validation → secure PriceTag session cookie
```

Do not store access or refresh tokens in browser local storage.

## Required SSO inputs

- issuer/discovery URL;
- client registration and client ID per environment;
- redirect and post-logout URIs;
- JWKS endpoint and key-rotation behavior;
- `openid`, `profile`, `email`, and group/role scopes;
- stable subject claim semantics;
- username, email, display-name, and group claims;
- token/session lifetime and refresh policy;
- ordinary-user, manager, and super-admin test identities.

Example callback:

```text
https://dashboard-enmaas.praxis-proxy.net/oauth/callback
```

Use the immutable OIDC `sub` claim as the identity key. Email is display/contact
data, not the primary identifier.

## Authorization and migration

SSO replaces browser login, not necessarily inference API keys immediately:

```text
Dashboard: OIDC/SSO
Inference clients: scoped API keys bound to the SSO subject
Future CLI: device flow or token exchange where appropriate
```

API keys created after SSO should carry subject, groups, tenant, expiration, and
policy scope. Atlas and Budget Tool should use service identity, not user
sessions or shared super-admin credentials.

## Security requirements

- Validate issuer, audience, nonce, state, signature, and PKCE.
- Use Secure, HttpOnly, SameSite session cookies.
- Refresh JWKS keys without restart.
- Fail closed for invalid identity.
- Audit login, logout, provisioning, role changes, and impersonation.
- Preserve a controlled break-glass process outside normal user sessions.

## Acceptance criteria

- Dashboard works from approved public or VPN-only hostnames.
- Existing inference keys remain functional during migration.
- User/group/manager authorization tests pass.
- Tokens never reach browser JavaScript, logs, or provider requests.
