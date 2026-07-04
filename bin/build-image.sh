#!/bin/bash -e

# shellcheck disable=SC1091
source "$(dirname "$0")/../share/build-functions.sh"

registry_auth
exit_if_image_present

harbor_rewrite_dockerfile

DOCKERFILE_DIR="$(dirname "${DOCKERFILE}")"
DOCKERFILE_NAME="$(basename "${DOCKERFILE}")"

OUTPUT="type=image,name=${FULL_IMAGE}"
if [ -z "${SKIP_DOCKER_PUSH}" ]; then
  OUTPUT="${OUTPUT},push=true"
fi

mkdir -p results

echo "Building image ${FULL_IMAGE} for platforms ${PLATFORMS}..."
buildctl-daemonless.sh build \
  --frontend dockerfile.v0 \
  --local context="${BUILD_DIR}" \
  --local dockerfile="${DOCKERFILE_DIR}" \
  --opt filename="${DOCKERFILE_NAME}" \
  --opt platform="${PLATFORMS}" \
  "${BUILD_OPTS[@]}" \
  --output "${OUTPUT}" \
  --metadata-file results/metadata.json

if [ -n "${SKIP_DOCKER_PUSH}" ]; then
  echo "SKIP_DOCKER_PUSH set - image built but not pushed."
else
  DIGEST=$(jq -r '."containerimage.digest" // empty' results/metadata.json)
  echo "Pushed ${FULL_IMAGE}@${DIGEST}"
fi

if [ -n "$BUILD_HELM_CHART" ]; then
  build-helm.sh
fi
