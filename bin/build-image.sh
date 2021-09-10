#!/bin/bash -e

# shellcheck disable=SC1091
source "$(dirname "$0")/../share/build-functions.sh"

if [ -z "${MULTIARCH}" ]; then
  IMAGE_NAME=${FULL_IMAGE}
else
  IMAGE_NAME=${FULL_IMAGE_ARCH}
fi

gitlab_login
exit_if_image_present

if [ -n "${MULTIARCH}" ] && [ "${ARCH}" != "" ] && [ "${ARCH}" != "amd64" ]; then
  set +e
  docker run --privileged --rm tonistiigi/binfmt --install "${ARCH}"
  set -e
fi

echo "Building Docker image ${IMAGE_NAME}..."
docker build --no-cache --pull --platform "${PLATFORM}" -t "$IMAGE_NAME" -f "$DOCKERFILE" "${BUILD_ARGS[@]}" "$BUILD_DIR"

mkdir -p results

echo "Pushing Docker image ${IMAGE_NAME}..."
docker push "$IMAGE_NAME"

if [ -n "$MULTIARCH" ]; then
  FULL_IMAGE_ARCH_SHA=$(docker inspect --format='{{ index .RepoDigests 0 }}' "$IMAGE_NAME")
  mkdir -p "${BUILD_DIR}/results"
  echo "$FULL_IMAGE_ARCH_SHA" > "${BUILD_DIR}/results/${ARCH}"
fi
