# Temporary EnMaaS stage

This environment is a two-week bridge while access to the AppSRE stage cluster
`hcmais01ue1` is completed. It runs on the non-production
`models-arch-ocp` ROSA cluster, never on `enmaas-prod`.

| Property | Value |
|---|---|
| API server | `https://api.models-arch-ocp.ijxt.p3.openshiftapps.com:443` |
| Namespace | `enmaas-stage` |
| Planned retirement | 2026-10-17 |
| Database | single-instance, stage-local CNPG; no production RDS access |
| Routes | cluster apps-domain hosts; no production DNS names |
| Secrets | generated stage values; never copied from production |
| Intended use | Atlas/API integration, upgrade rehearsal, functional tests |
| Explicitly excluded | load/performance tests and production traffic |

## Safety boundary

`tools/bootstrap-temporary-stage.sh` has an exact API-server guard and refuses
the production server. The bootstrap creates only the namespace, ResourceQuota,
LimitRange and default-deny NetworkPolicy. It does not install cluster-scoped
operators, CRDs or application RBAC.

```bash
oc login https://api.models-arch-ocp.ijxt.p3.openshiftapps.com:443
CONFIRM_TEMPORARY_STAGE=true ./tools/bootstrap-temporary-stage.sh
```

Application installation is a separate reviewed step. Before it is allowed:

1. Build MaaS API, metering-service and Praxis from pinned source commits into
   the stage cluster's registry.
2. Render manifests offline and reject every production hostname, namespace,
   RDS endpoint, certificate Secret and provider credential reference.
3. Install cluster prerequisites only on `models-arch-ocp`.
4. Add NetworkPolicies with each workload; default-deny stays throughout.
5. Use generated partner/API/session secrets and a stage-only test identity.
6. Run the functional suite against stage before exposing it to Atlas.

## Teardown

Delete `enmaas-stage` after AppSRE stage is usable, then confirm its PVCs and
Routes are gone. Any cluster-scoped prerequisite installed solely for this
environment must be reviewed separately before removal because another
namespace may have adopted it.
