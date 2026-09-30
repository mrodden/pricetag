#!/usr/bin/env python3
"""Inject EnMaaS-only Vertex fragments into the rendered Praxis ConfigMap."""

from pathlib import Path
import os
import re
import sys


def main() -> int:
    rendered_path = Path(sys.argv[1])
    fragments_dir = Path(sys.argv[2])
    rendered = rendered_path.read_text()
    fragments = {
        "MODEL_CATALOG": "model-catalog.yaml",
        "MODEL_TO_PROVIDER_FILTER": "model-to-provider.yaml",
        "ROUTER_ROUTE": "router-route.yaml",
        "FILTER": "vertex-filter.yaml",
        "GCP_CREDENTIAL_FILTER": "gcp-credential-filter.yaml",
        "HOST_OVERRIDE": "vertex-host-override.yaml",
        "UPSTREAM_CLUSTER": "vertex-cluster.yaml",
        "ONLY_ACCESS": "vertex-only-access.yaml",
        "ONLY_MODEL_CATALOG": "vertex-only-model-catalog.yaml",
        "METERING_INTERNAL_AUTH": "metering-internal-auth.yaml",
    }

    for marker, filename in fragments.items():
        pattern = re.compile(rf"(?m)^(?P<indent>[ \t]*)# ENMAAS_VERTEX_{marker}\s*$")
        snippet = (fragments_dir / filename).read_text().rstrip("\n").splitlines()

        def replace(match: re.Match[str]) -> str:
            indent = match.group("indent")
            return "\n".join(f"{indent}{line}" if line else indent for line in snippet)

        rendered, replacements = pattern.subn(replace, rendered)
        expected = 3 if marker == "METERING_INTERNAL_AUTH" else 1
        if replacements != expected:
            raise ValueError(f"expected {expected} insertion markers for {marker}, found {replacements}")

    model_policy_check = os.environ.get("METERING_MODEL_POLICY_CHECK", "false")
    if model_policy_check not in {"true", "false"}:
        raise ValueError("METERING_MODEL_POLICY_CHECK must be true or false")
    policy_pattern = re.compile(r"(?m)^(?P<indent>[ \t]*)# ENMAAS_METERING_MODEL_POLICY\s*$")

    def replace_model_policy(match: re.Match[str]) -> str:
        if model_policy_check == "true":
            return f'{match.group("indent")}model_policy_check: true'
        return ""

    rendered, policy_replacements = policy_pattern.subn(replace_model_policy, rendered)
    if policy_replacements != 3:
        raise ValueError(f"expected three metering model-policy markers, found {policy_replacements}")

    sys.stdout.write(rendered)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, IndexError) as error:
        print(f"render-enmaas-vertex: {error}", file=sys.stderr)
        raise SystemExit(1) from error
