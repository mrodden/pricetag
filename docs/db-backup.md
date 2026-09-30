# Database backup & HA (dogfood PriceTag cluster)

Namespace `ai-gateway-dogfood`. The `aigateway` database holds cost/audit
rollups, people, invites, and maas-api key hashes — it is the source for
leader-facing cost reporting, so loss is not an option and restore-to-last-
month is a requirement.

## Architecture

| Layer | What | Where |
|---|---|---|
| Database | CloudNativePG `aigateway-pg`, 3 instances, streaming replication, auto-failover | `deploy/cnpg/10-cluster.yaml` |
| Continuous backups | WAL archiving (gzip) → IBM COS | barmanObjectStore on the Cluster |
| Physical backups | Daily base backup 02:15 UTC | `deploy/cnpg/20-scheduled-backup.yaml` |
| Off-cluster target | Environment-specific COS bucket and endpoint | provisioned by `deploy/provision-cos-backup-target.sh` |
| Credentials | `ai-gateway-dogfood/cnpg-backup-cos` (HMAC Writer key, COS instance-scoped) | same provisioner; re-running rotates the key |
| Stopgap (pre-cutover) | nightly `pg_dump` CronJob → `postgres-backups` PVC, 14-day retention — **SUSPENDED since cutover 2026-09-16** | `deploy/postgres-backup-stopgap.yaml` |

> **Cutover executed 2026-09-16 03:22–04:10 UTC.** CNPG `aigateway-pg`
> is now the live database for maas-api + metering-service. `postgresql-0`
> was scaled to 0 at 04:10Z the same morning, after `pg_stat_activity`
> showed zero clients and live CNPG writes were re-proven; its PVC and
> the `postgresql-credentials-pre-cnpg` + `maas-db-config-pre-cnpg`
> secrets are kept as rollback insurance (verified `0/0`, not deleted,
> 2026-09-18), so rollback is one command:
> `oc -n ai-gateway-dogfood scale sts postgresql --replicas=1` + repoint
> step 8's secrets back. Manual base
> backup `manual-check` completed to COS at 03:44Z. Two incidents are
> documented in `deploy/cnpg/40-*.yaml` (inverted-diff duplicate inserts,
> repaired by `50-repair-usage-events.yaml`; end state verified: zero
> rows from old missing on CNPG, 114 dupes removed) and step 8 below
> (maas-api's second DSN secret).

Recovery objectives this gives us: RPO ≈ seconds (WAL shipping), RTO ≈ a
restore-job spin-up; any point in time since the oldest base backup is
restorable, which covers "give me last month's numbers" and
"restore to right before that bad migration".

## EnMaaS AWS/ROSA backup setup

### EnMaaS RDS transition

As of 2026-09-29, EnMaaS application reads and writes use AWS RDS
`enmaas-db`; the CNPG cluster remains running only as rollback insurance. The
CNPG S3/WAL procedure below does not back up the live RDS database.

RDS currently provides Multi-AZ availability, encrypted gp3 storage,
deletion protection, and seven-day automated backup retention. Before treating
the migration as complete, verify RDS point-in-time recovery and a restore to
a disposable instance. Review the current `PubliclyAccessible` setting and
security groups: database access should be limited to the EnMaaS network and
approved operators.

The RDS cutover used a final writer drain, a snapshot-consistent `pg_dump`,
restore into the `aigateway` database, separate application/read-only roles,
then a coordinated update of `maas-db-config`, `postgresql-credentials`, and
`metering-readonly-db-url`. Rollback is still possible by restoring those
connection Secrets and restarting MaaS API and metering while CNPG remains
available.

Do not decommission CNPG, its storage, or its rollback material until the
RDS backup/restore drill, ledger idempotency gate, and an observation window
are complete.

The EnMaaS practice profile is separate from the IBM Cloud production profile.
It runs in AWS `us-west-2` and uses the AWS S3 bucket configured by
`deploy/openshift/database/cnpg/10-cluster-enmaas.yaml`:

Provision or reconcile the AWS prerequisites with
`deploy/openshift/provision-aws-backup-target.sh` before running `deploy.sh`.
The provisioner is idempotent and does not delete bucket data or put AWS keys
in Kubernetes.

| Layer | EnMaaS configuration |
|---|---|
| Object store | Private, versioned, SSE-encrypted S3 bucket in `us-west-2` |
| Retention | 30 days by default via `S3_RETENTION_DAYS`; choose 90/180 days for a longer recovery window |
| Authentication | IAM role `pricetag-enmaas-cnpg-backup` via OpenShift OIDC workload identity |
| ServiceAccount | `enmaas/aigateway-pg` |
| CNPG credentials | `s3Credentials.inheritFromIAMRole: true`; no AWS key Secret |
| OIDC audience | `openshift` (the token claim is an array; use `ForAnyValue:StringEquals`) |
| Required IAM actions | Bucket location/list plus object read/write/delete and multipart operations, scoped to the bucket |

The IAM role trust policy must restrict the EnMaaS OIDC provider to the target
cluster's issuer and:

```text
aud: openshift
sub: system:serviceaccount:enmaas:aigateway-pg
```

Before deploying, verify the bucket, cluster OIDC issuer, `gp3-csi` storage
class, and role. `deploy.sh` does not create AWS resources or copy AWS
credentials. After deployment, prove the path end-to-end with a manual backup:

```bash
oc -n enmaas apply -f - <<'YAML'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: aigateway-manual-<timestamp>
spec:
  cluster:
    name: aigateway-pg
YAML

oc -n enmaas get backup aigateway-manual-<timestamp> \
  -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,DESTINATION:.status.destinationPath'
oc -n enmaas get cluster aigateway-pg \
  -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].reason}{"\n"}'
```

The backup must reach `completed` and continuous archiving must report
`ContinuousArchivingSuccess`. Do not use the IBM COS Secret or the production
cutover steps below for EnMaaS. Lifecycle expiration is automatic object
retention, not a renewal requirement; it does not stop new backups or the
database, but it does remove restore points older than the configured window.

## Cutover runbook (old postgresql-0 → aigateway-pg)

All commands from a terminal logged into the cluster (`oc login` done,
`-n ai-gateway-dogfood` assumed below). Old pod stays scaled to zero,
PVC untouched, until confidence; rollback = repoint the secret back.

1. **Install the operator** — community manifest, not OLM (the marketplace
   listing is EDB's paywalled repackage; see `deploy/cnpg/README.md`):
   ```bash
   # if a previous EDB Subscription attempt exists, clear it first:
   oc -n ai-gateway-dogfood delete subscription cloud-native-postgresql \
     operatorgroup ai-gateway-dogfood-operators --ignore-not-found
   oc -n ai-gateway-dogfood delete csv cloud-native-postgresql.v1.29.0 --ignore-not-found
   oc -n ai-gateway-dogfood delete installplan install-qjthh --ignore-not-found
   # then:
   oc apply -f deploy/cnpg/cnpg-operator-1.30.0.yaml
   oc -n cnpg-system wait deploy/cnpg-controller-manager --for=condition=Available --timeout=5m
   ```
2. **App credentials** (new real password; the old one is a CHANGE-ME
   placeholder and dies with this cutover):
   ```bash
   NEWPW=$(openssl rand -base64 40 | tr -dc 'A-Za-z0-9' | cut -c1-28)
   oc -n ai-gateway-dogfood create secret generic aigateway-db-app \
     --from-literal=username=aigateway --from-literal=password="$NEWPW" \
     --dry-run=client -o yaml | oc -n ai-gateway-dogfood apply -f -
   ```
3. **Cluster** — `oc apply -f deploy/cnpg/10-cluster.yaml`, wait for 3/3:
   `oc -n ai-gateway-dogfood wait cluster aigateway-pg --for condition=Ready --timeout=10m`
4. **Freeze the writers — and ONLY the writers**:
   `oc -n ai-gateway-dogfood scale deploy/maas-api deploy/metering-service --replicas=0`
   (verify `readyReplicas=0` before the dump). **NEVER scale praxis** —
   it is the team-wide LLM gateway, it does not write to this database,
   and taking it down is a team outage, not a freeze. Data movement
   itself needs no freeze: dump/restore against the live DB is
   snapshot-consistent; only the ~30s repoint window uses the freeze.
5. **Fresh dump of the old pod** (it is still up; this shrinks the loss
   window to minutes): `oc -n ai-gateway-dogfood create job pre-cutover-dump --from=cronjob/postgres-backup-dump`
   then `oc -n ai-gateway-dogfood wait job/pre-cutover-dump --for=condition=Complete --timeout=10m`
6. **Load CNPG** — `oc -n ai-gateway-dogfood delete job cnpg-restore --ignore-not-found; oc apply -f deploy/cnpg/30-restore-job.yaml`,
   wait: `oc -n ai-gateway-dogfood wait job/cnpg-restore --for=condition=Complete --timeout=20m`
7. **Verify parity** — table counts identical between
   `oc -n ai-gateway-dogfood exec -i postgresql-0 -- psql -U aigateway -d aigateway`
   and `oc -n ai-gateway-dogfood exec -i aigateway-pg-1 -c postgresql -- psql -U aigateway -d aigateway`
   (`SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY 1;` in both —
   approximate counts can drift slightly, 0 vs N cannot).
8. **Repoint the apps** (backs up the old secret cluster-side first):
   ```bash
   oc -n ai-gateway-dogfood get secret postgresql-credentials -o json \
     | python3 -c "import json,sys;s=json.load(sys.stdin);s['metadata']={'name':'postgresql-credentials-pre-cnpg','namespace':'ai-gateway-dogfood'};print(json.dumps(s))" \
     | oc -n ai-gateway-dogfood apply -f -
   NEWPW=$(oc -n ai-gateway-dogfood get secret aigateway-db-app -o jsonpath='{.data.password}' | base64 -d)
   for K in MAAS_DB_URL METERING_DB_URL; do
     V="postgresql://aigateway:${NEWPW}@aigateway-pg-rw:5432/aigateway?sslmode=disable"
     oc -n ai-gateway-dogfood patch secret postgresql-credentials --type merge \
       -p "{\"data\":{\"$K\":\"$(printf %s "$V" | base64)\"}}"
   done
   oc -n ai-gateway-dogfood patch secret postgresql-credentials --type merge \
     -p "{\"data\":{\"POSTGRES_PASSWORD\":\"$(printf %s "$NEWPW" | base64)\"}}"
   ```
   **maas-api does not read `MAAS_DB_URL` above at all** (learned the hard
   way, 2026-09-16): it loads its DSN from a DIFFERENT secret —
   `maas-db-config`, key `DB_CONNECTION_URL` — via the K8s API at startup
   (`LoadDatabaseURL` in maas-api's config.go). Patch it too, back it up,
   and restart maas-api, or it silently keeps writing to the old pod:
   ```bash
   oc -n ai-gateway-dogfood get secret maas-db-config -o json \
     | python3 -c "import json,sys;s=json.load(sys.stdin);s['metadata']={'name':'maas-db-config-pre-cnpg','namespace':'ai-gateway-dogfood'};print(json.dumps(s))" \
     | oc -n ai-gateway-dogfood apply -f -
   oc -n ai-gateway-dogfood patch secret maas-db-config --type merge \
     -p "{\"data\":{\"DB_CONNECTION_URL\":\"$(printf %s "postgresql://aigateway:${NEWPW}@aigateway-pg-rw:5432/aigateway?sslmode=disable" | base64)\"}}"
   oc -n ai-gateway-dogfood rollout restart deploy/maas-api
   ```
   After repointing, prove no client is left on the old db:
   `oc exec -i postgresql-0 -- psql -U aigateway -d aigateway -c "SELECT client_addr,count(*) FROM pg_stat_activity WHERE datname='aigateway' GROUP BY 1;"`
   must return zero rows. (metering-service reads the DSN as env
   `DATABASE_URL` ← `postgresql-credentials/METERING_DB_URL`; a pod
   restart (scale 0→1 or rollout restart) is required after patching the
   secret either way.)
9. **Resume** — `oc -n ai-gateway-dogfood scale deploy/maas-api deploy/metering-service --replicas=1`,
   smoke-test the dashboard + a key lookup. (praxis was never touched; if
   it ever was, restoring its 2 replicas is the first thing you do.)
10. **Decommission slowly**: suspend the stopgap CronJob
    (`oc -n ai-gateway-dogfood patch cronjob postgres-backup-dump -p '{"spec":{"suspend":true}}'`),
    after 24h healthy scale the old pod down
    (`oc -n ai-gateway-dogfood scale sts postgresql --replicas=0`); keep the
    PVC and `postgresql-credentials-pre-cnpg` for a week. Rollback during
    that window = step 8's secret from the backup + scale back up.
11. **Prove backups work**: `oc -n ai-gateway-dogfood create backup manual-check --cluster=aigateway-pg` (or
    wait for 02:15), check the `Backup` resource reaches Completed, and
    confirm WAL archiving: `oc -n ai-gateway-dogfood get cluster aigateway-pg -o jsonpath='{.status.phase}'` plus
    objects appearing under `s3://aigateway-dogfood-backups-b6bd93/`.
    PITR restore drill: build a `bootstrap.recovery` Cluster pointing at the
    bucket — read the schema from the **installed** operator
    (`oc get crd clusters.postgresql.cnpg.io -o json` → `bootstrap.recovery`)
    since that stanza's shape moved across CNPG versions.

## Known caveats

- The COS Writer key is **instance-scoped** (covers every bucket in
  `myvpc-cos`); bucket-scoped HMAC credentials aren't scriptable on this
  account. A dedicated COS instance would scope it — its creation
  silently fails on this account (see comments in the provisioner).
- Bucket retention is not yet lifecycle-managed; until set, backups
  accumulate forever (cheap, but unbounded). Set a COS lifecycle rule
  keeping e.g. 30 base backups.
- `backup.barmanObjectStore` (native) is **deprecated in CNPG 1.30** and
  removed in 1.31 — the operator applies it with a warning today. Before
  upgrading the operator past 1.30.x, migrate backups to the Barman Cloud
  *plugin* architecture (per CNPG 1.31 migration notes); the bucket,
  endpoint, and HMAC secret all stay as-is.
- OpenShift SCC note: this cluster's admission only honors the `-v2` SCCs.
  Both SAs need `nonroot-v2` (granted: `cnpg-manager` in `cnpg-system` for
  the operator, `aigateway-pg-cluster` in `ai-gateway-dogfood` for the
  Postgres instances, which pin uid 26). Legacy `nonroot` grants are inert
  here — don't be fooled by `add-scc-to-user` reporting success.
- App DSNs use `sslmode=disable` (unchanged from the old setup; CNPG
  accepts it). Tighten to `sslmode=require` + cluster CA later.
- `postgres-backups` PVC stays around after decommissioning the stopgap —
  it holds the dumps the cutover itself was loaded from.
