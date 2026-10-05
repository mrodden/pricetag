# EnMaaS RDS debug client

`deploy/openshift/operations/rds-debug.yaml` provides a hardened PostgreSQL 16
`psql` client in the production namespace. It is optional and defaults to zero
replicas. The client mounts only `metering-readonly-db-url`, so it cannot modify
the database even if an unsafe query is pasted.

## Install once

```bash
oc apply -f deploy/openshift/operations/rds-debug.yaml
```

The NetworkPolicy remains installed and selects only `rds-debug` pods.

## Start and connect

```bash
oc -n enmaas scale deployment/rds-debug --replicas=1
oc -n enmaas rollout status deployment/rds-debug --timeout=3m
oc -n enmaas exec -it deployment/rds-debug -- sh -c 'psql "$DATABASE_URL"'
```

The single quotes ensure `$DATABASE_URL` is expanded inside the container, not
on the workstation. Do not copy the DSN locally or pass it in shell history.

Useful read-only checks:

```sql
SELECT current_user, current_database(), version();
SELECT count(*) FROM usage_events;
SELECT pg_size_pretty(pg_total_relation_size('usage_events'));
SELECT relname, n_live_tup, n_dead_tup, seq_scan, idx_scan
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(relid) DESC;
```

## Stop

```bash
oc -n enmaas scale deployment/rds-debug --replicas=0
```

Scaling preserves the Deployment and policy for the next investigation while
removing the running pod. `HOME` and psql history use a bounded ephemeral
volume and disappear with the pod.
