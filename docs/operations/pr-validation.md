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
- EnMaaS Vertex-only model/configuration contract.
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
