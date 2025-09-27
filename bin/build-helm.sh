#!/bin/bash -ex

# shellcheck disable=SC1091
source "$(dirname "$0")/../share/build-functions.sh"

IMAGE_NAME="${HELM_CHART_IMAGE}"

gitlab_login

echo "Building Helm chart ${IMAGE_NAME}..."

helm dependency build "$HELM_CHART_DIR"

HELM_CHART_VERSION="0.0.0-$(git rev-parse --short HEAD)"
APP_VERSION="$TAG"

helm package "$HELM_CHART_DIR" \
  --version "$HELM_CHART_VERSION" \
  --app-version "$APP_VERSION"

if [ -z "${SKIP_DOCKER_PUSH}" ]; then
  echo "Pushing Helm chart ${IMAGE_NAME}..."
  helm push "${HELM_CHART_NAME}-${HELM_CHART_VERSION}.tgz" "$IMAGE_NAME"
fi
