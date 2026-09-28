# Organization Chart and Manager Authorization Design

## Goal

Provide correct manager visibility and approval behavior without trusting
client-supplied hierarchy headers.

Required visibility rules:

- ordinary user: self only;
- manager: self and all descendants;
- manager cannot see peer managers;
- a manager's manager sees their own descendant tree;
- super-admin is the explicit exception and is audited.

## Source of truth

SSO groups identify roles and memberships, but groups alone rarely represent a
complete reporting tree. Reporting relationships should come from an
authoritative HR/directory/SCIM/Graph source.

PriceTag should maintain a normalized projection containing:

- immutable subject ID;
- display name and email;
- current groups and roles;
- manager subject ID;
- effective dates and source timestamp;
- active/departed state.

Reject cycles, self-management, duplicate identities, and ambiguous managers.

## Authorization model

All dashboard and Budget Tool scope calculations must use the server-side
directory projection. Client identity or manager headers are never trusted as
authorization input without verification at the identity boundary.

The evaluator should resolve the authenticated subject, compute descendants,
apply resource scope, deny peers/unrelated users, and record actor, effective
subject, scope, and decision. Super-admin impersonation must preserve both
identities in the audit record.

## Synchronization

Use event-driven updates plus periodic reconciliation. A stale or failed sync
must retain the last-known-good graph and alert; it must never widen visibility.

## Acceptance criteria

- Tests cover self, descendant, peer, ancestor, cycles, departures, and
  super-admin access.
- URL/query/header changes cannot widen a manager's scope.
- Dashboard and Budget Tool share the same scope evaluator.
- Sync lag and rejected graph updates are observable.
- No prompt or response content is stored for identity synchronization.
