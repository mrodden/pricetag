# Pull Request Validation

PriceTag has a fast, non-mutating Pull Request validation workflow:

```text
.github/workflows/pr-validation.yml
  → tools/validate-pr.sh
```

## What it validates

- Shell syntax for deployment scripts.
- Python syntax for renderers and tools.
- Whitespace and patch cleanliness.
- Required production/deployment safety guards.
- Kustomize rendering for `test`, `dogfood`, and `enmaas` profiles.
- EnMaaS Vertex fragment injection and nested Praxis configuration syntax.
- EnMaaS public route contract.
- EnMaaS provider/model configuration contract.
- Credential-pattern scans over tracked files.

## Safety boundary

The PR job does not:

- log into OpenShift;
- contact production or EnMaaS;
- build or push images;
- use deployment Secrets;
- call external hosted-model providers;
- mutate Kubernetes resources.

The workflow has a ten-minute hard timeout and cancels superseded runs for the
same Pull Request. Full image builds, disposable-cluster tests, external
provider tests, upgrades, rollback, and backup/restore qualification belong in
separate scheduled or pre-release jobs.

## Static security baseline

The separate `security-static.yml` workflow intentionally reports the current
EnMaaS security baseline gaps rather than hiding them behind a warning. Its
first run is expected to fail until the following are remediated:

- default-deny NetworkPolicies and the required allowlist are present;
- Praxis admin is not publicly bound or exposed by the Service;
- Praxis, MaaS API, and metering pods declare explicit hardened security
  contexts and disable unnecessary ServiceAccount token automounting;
- application images are immutable/digest-pinned;
- public dashboard routing has a private/authenticated boundary for internal
  entitlement and event APIs.

The baseline is intentionally separate from the fast general regression gate:
the general gate protects ordinary PR quality now, while this job provides the
fail-then-fix security workstream. Once the baseline is green and the live
security checks exist, it should become a required merge check.
