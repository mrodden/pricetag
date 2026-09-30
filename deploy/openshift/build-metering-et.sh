#!/usr/bin/env bash
# Build the canonical ET PriceTag metering service in the target OpenShift
# cluster and return its immutable ImageStream tag.

set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

: "${NAMESPACE:?Set NAMESPACE to the target namespace}"
: "${METERING_SOURCE_SHA:?Set METERING_SOURCE_SHA to a pushed metering commit}"

METERING_SOURCE_REPO="${METERING_SOURCE_REPO:-https://github.com/redhat-et/pricetag-metering.git}"
BUILD_CONFIG_NAME="${BUILD_CONFIG_NAME:-pricetag-metering-et}"
IMAGE_STREAM_NAME="${IMAGE_STREAM_NAME:-metering-service}"
IMAGE_TAG="practice-metering-${METERING_SOURCE_SHA:0:8}"

[[ "$METERING_SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] || \
  die "METERING_SOURCE_SHA must be a full 40-character commit SHA"

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
      uri: ${METERING_SOURCE_REPO}
      ref: ${METERING_SOURCE_SHA}
  strategy:
    type: Docker
    dockerStrategy:
      dockerfilePath: Dockerfile
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
printf 'Built ET metering source %s; digest %s\n' \
  "$METERING_SOURCE_SHA" "$IMAGE_DIGEST" >&2
