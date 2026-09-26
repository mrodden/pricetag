#!/usr/bin/env bash
# Build the ET Praxis source in the target OpenShift cluster and return the
# immutable ImageStream tag. The source is fetched from a pushed ET commit.

set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

: "${NAMESPACE:?Set NAMESPACE to the target namespace}"
: "${PRAXIS_SOURCE_SHA:?Set PRAXIS_SOURCE_SHA to a pushed ET praxis-ai commit}"

PRAXIS_SOURCE_REPO="${PRAXIS_SOURCE_REPO:-https://github.com/redhat-et/praxis-ai.git}"
PRAXIS_AI_FEATURES="${PRAXIS_AI_FEATURES:-full,gcp-adc-filter}"
BUILD_CONFIG_NAME="${BUILD_CONFIG_NAME:-pricetag-praxis-et}"
IMAGE_STREAM_NAME="${IMAGE_STREAM_NAME:-praxis-ai}"
IMAGE_TAG="practice-${PRAXIS_SOURCE_SHA:0:8}"

[[ "$PRAXIS_SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] || \
  die "PRAXIS_SOURCE_SHA must be a full 40-character commit SHA"
[[ "$PRAXIS_AI_FEATURES" == full,gcp-adc-filter ]] || \
  die "PRAXIS_AI_FEATURES must be full,gcp-adc-filter for the Vertex trial"

oc -n "$NAMESPACE" apply -f - >&2 <<YAML
apiVersion: image.openshift.io/v1
kind: ImageStream
metadata:
  name: ${IMAGE_STREAM_NAME}
---
apiVersion: build.openshift.io/v1
kind: BuildConfig
metadata:
  name: ${BUILD_CONFIG_NAME}
spec:
  runPolicy: Serial
  source:
    type: Git
    git:
      uri: ${PRAXIS_SOURCE_REPO}
      ref: ${PRAXIS_SOURCE_SHA}
  strategy:
    type: Docker
    dockerStrategy:
      dockerfilePath: Containerfile
      buildArgs:
        - name: PRAXIS_AI_FEATURES
          value: ${PRAXIS_AI_FEATURES}
  output:
    to:
      kind: ImageStreamTag
      name: ${IMAGE_STREAM_NAME}:${IMAGE_TAG}
YAML

oc -n "$NAMESPACE" start-build "bc/${BUILD_CONFIG_NAME}" --wait >&2

IMAGE_DIGEST="$(oc -n "$NAMESPACE" get istag "${IMAGE_STREAM_NAME}:${IMAGE_TAG}" \
  -o jsonpath='{.image.dockerImageReference}' | sed 's/.*@//')"
[[ "$IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || \
  die "build output has no immutable image digest"

printf '%s\n' "$IMAGE_TAG"
printf 'Built ET Praxis source %s with %s; digest %s\n' \
  "$PRAXIS_SOURCE_SHA" "$PRAXIS_AI_FEATURES" "$IMAGE_DIGEST" >&2
