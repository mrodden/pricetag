# EnMaaS RDS migration runbook

This runbook records the staged migration of the isolated EnMaaS PriceTag
database from CloudNativePG to AWS RDS. It is not a production runbook.

## Current target

- AWS account: `624013087577`
- Region: `us-west-2`
- RDS instance: `enmaas-db`
- Database: `aigateway`
- Application roles: `aigateway`, `metering_reader`
- Application connection Secrets: `maas-db-config`,
  `postgresql-credentials`, and `metering-readonly-db-url`

## Staged cutover sequence

1. Verify CNPG health, successful backup/archiving, and zero duplicate
   `usage_events.event_id` values.
2. Verify RDS, security groups, TLS, backup retention, and restore policy. Do
   not use the RDS administrative user for applications.
3. Create the target database and least-privilege roles.
4. Perform an initial snapshot-consistent dump/restore while applications stay
   live.
5. Validate table counts, event-ID uniqueness, API-key count, pricing rows,
   rollups, and representative read-only queries.
6. During a controlled maintenance window, stop `praxis`, `maas-api`, and
   `metering-service`; wait for usage-event delivery to drain.
7. Repeat the dump/restore from the frozen CNPG source. Exclude only obsolete
   backup artifacts; never exclude application tables.
8. Update all three application connection Secrets together:
   - `maas-db-config/DB_CONNECTION_URL`;
   - `postgresql-credentials/MAAS_DB_URL` and `METERING_DB_URL`;
   - `metering-readonly-db-url/READ_DATABASE_URL`.
9. Start MaaS API, metering, and Praxis; wait for readiness and verify new RDS
   connections.
10. Run API-key validation, entitlement, GLM, Anthropic/Vertex, OpenAI, and
    dashboard smoke tests. Confirm a new usage event lands in RDS.
11. Keep CNPG and rollback material available through an observation window.
12. After the observation window, hibernate CNPG rather than deleting it. This
    removes its Pods while retaining all PVCs as a cold rollback copy, and
    suspends its ScheduledBackup so a stale database is not archived forever.
13. Only after backup/restore, idempotency, performance, and rollback gates
    pass may CNPG and its PVCs be deleted permanently.

## Post-cutover key reconciliation — 2026-09-29

The old dogfood database was compared with RDS by API-key hash, not by
plaintext credentials. Existing RDS rows were preserved; missing old rows were
inserted idempotently, including associated people, identities, and profiles.

- Hanna Loboda's existing key was present in both environments.
- 16 active key rows for 15 other users were missing from RDS and were copied.
- The old identity/profile rows were reconciled without overwriting newer RDS
  records.
- RDS now contains 352 API-key rows, 156 active rows, 283 people, 177
  identities, and 101 user profiles.
- The full GLM/MaaS/dashboard/RDS coverage gate passed after reconciliation.

Plaintext API keys were never extracted from the old database: only stored key
hashes and associated metadata were migrated.

## Rollback

RDS mode declaratively hibernates the legacy cluster with
`cnpg.io/hibernation: "on"`. CloudNativePG removes all database Pods but
retains the primary and replica PVCs. It also suspends `aigateway-daily`.

To make the rollback source available again:

```bash
oc -n enmaas annotate cluster/aigateway-pg --overwrite cnpg.io/hibernation=off
oc -n enmaas wait cluster/aigateway-pg --for=condition=Ready --timeout=10m
```

Do not resume the legacy backup schedule: the object-store archive belongs to
the pre-cutover timeline and RDS is the backup authority after cutover.

Then stop application writers, restore the pre-RDS connection Secret values,
restart MaaS API and metering, restore Praxis if needed, and verify that new
connections return to CNPG. Do not delete CNPG or its storage until rollback
has been explicitly retired.

## Required gates before decommissioning CNPG

## Capacity baseline — 2026-09-29

The following benchmark exercised the metering entitlement GET path through
the two-replica metering service using synthetic identities. It performed
read-only checks only; it did not call a provider or create usage events.

| Concurrent checks | Requests | Success | p50 | p95 | p99 | Max |
|---:|---:|---:|---:|---:|---:|---:|
| 50 | 752 | 752 | 146 ms | 495 ms | 524 ms | 525 ms |
| 100 | 1,309 | 1,309 | 195 ms | 587 ms | 625 ms | 679 ms |
| 250 | 2,971 | 2,971 | 326 ms | 632 ms | 671 ms | 727 ms |

RDS CloudWatch observations after the benchmark were approximately:

- CPU average 2%; peak below 3%;
- maximum connections 19;
- DB load maximum 1;
- read latency 0 seconds; write latency approximately 7 ms.

The post-test GLM inference, model discovery, dashboard health/readiness, and
RDS ledger checks all passed. This is a bounded baseline, not a 700-user SLO:
the next test should use sustained traffic, realistic request rates, and
application pool-wait metrics.

- RDS automated backup and point-in-time restore verified.
- RDS security groups no longer permit unnecessary public exposure.
- Unique `usage_events(event_id)` constraint installed after duplicate-safe
  application ingestion is deployed.
- RDS p95 entitlement and event-ingestion latency meet the agreed SLO.
- Two-replica metering behavior has no rollup/parity errors.
- A bounded read-only burst has been measured, but sustained 700-user traffic
  remains a separate load-test gate.
- Full rollback has been rehearsed or explicitly accepted by the owner.
