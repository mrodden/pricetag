# EnMaaS 200-key concurrency test

`tools/enmaas-key-load-test.py` validates distinct user keys under a coordinated
burst without exposing the keys in argv, logs or result files. It uses Python's
standard library only.

## Safety model

- The CSV must be mode `0600` and contain unique `sequence`, `user_id`, `email`
  and `key` columns.
- Console output identifies failures by sequence and SHA-256 key fingerprint,
  never plaintext key or email.
- JSON results contain UUIDs and fingerprints but no key material; output mode
  is `0600`.
- Production requires `--confirm-prod`.
- Inference requires the additional `--confirm-provider-traffic`.
- There are no retries. Capacity errors remain visible.
- Each request uses a fresh TLS connection, approximating distinct users rather
  than one client multiplexing 200 credentials.

## Validate the input without traffic

```bash
./tools/enmaas-key-load-test.py \
  --keys "$HOME/Downloads/Pertest-users.csv" \
  --validate-only
```

## Auth-only production ramp

`GET /v1/models` exercises DNS, router TLS, Praxis key authentication and MaaS
without calling a provider or creating usage events.

```bash
./tools/enmaas-key-load-test.py \
  --keys "$HOME/Downloads/Pertest-users.csv" \
  --base-url https://api.enmaas.devshift.net \
  --mode auth \
  --ramp 5,10,25,50,100,200 \
  --cooldown 30 \
  --confirm-prod
```

Default auth gates are zero failed requests, p95 at most one second and p99 at
most two seconds. The ramp stops at the first failed gate.

## Authentication-cache behavior

Run 200 users once, then rerun at 60 seconds (warm cache) and after 360 seconds
(past the current 300-second cache TTL). Use the same `--run-id` prefix or keep
the generated IDs with the results for correlation.

```bash
./tools/enmaas-key-load-test.py ... --concurrency 200 --confirm-prod
sleep 60
./tools/enmaas-key-load-test.py ... --concurrency 200 --confirm-prod
sleep 300
./tools/enmaas-key-load-test.py ... --concurrency 200 --confirm-prod
```

## Inference and metering

Run inference on staging first. The default is one GLM 5.3 Chat Completions
request per key with a 64-token output cap and a unique run/sequence marker.

```bash
./tools/enmaas-key-load-test.py \
  --keys "$HOME/Downloads/Pertest-users.csv" \
  --base-url https://<stage-gateway> \
  --mode inference \
  --ramp 5,10,25,50,100,200 \
  --model rits/zai-org/glm-5-3 \
  --confirm-provider-traffic
```

Before a production inference run, confirm the dollar cap, provider capacity,
test window, monitoring coverage and stop owner. Reconcile one metering event
per successful request using the CSV UUID mapping and the unique batch IDs.

## Realistic sustained traffic

Synchronized bursts answer a worst-case capacity question but do not resemble
normal interactive use. Sustained mode assigns each user a deterministic random
phase, then sends one request per interval with jitter:

```bash
./tools/enmaas-key-load-test.py \
  --keys "$HOME/Downloads/Pertest-users.csv" \
  --base-url https://api.enmaas.devshift.net \
  --mode inference \
  --model gpt-5.4 \
  --concurrency 200 \
  --duration-minutes 15 \
  --per-user-interval 60 \
  --jitter 0.20 \
  --confirm-prod \
  --confirm-provider-traffic
```

That produces roughly 3,000 requests over 15 minutes (about 3.3 requests per
second) while preventing artificial once-per-minute request waves. Run the same
shape per provider for a comparable latency and metering baseline.

## Observe and stop

Watch the EnMaaS Overview, Performance/SRE and RDS dashboards. Stop for any
workload restart, lost replica, monitoring target down, RDS connection
utilization above 70%, unexpected identity attribution, or 5xx/error rate above
the agreed threshold.

The result JSON includes per-request status, TTFB, total latency, response size,
UUID and key fingerprint. It is still operationally sensitive and should not be
committed.
