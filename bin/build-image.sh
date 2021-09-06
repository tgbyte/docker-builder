#!/bin/bash -e

# shellcheck disable=SC1091
source "$(dirname "$0")/../share/build-functions.sh"

if [ -z "$MULTIARCH" ]; then
  IMAGE_NAME=${FULL_IMAGE}
else
  IMAGE_NAME=${FULL_IMAGE_ARCH}
fi

if [ ! -e .trivy ]; then
  FORCE="1"
fi

if [ -e .trivy-vulnerable ]; then
  VULNERABLE="1"
fi

if [ "$FORCE" != "1" ] && [ -z "$VULNERABLE" ]; then
  echo Exit if "${FULL_IMAGE}" already exists
  check-tag.sh "${FULL_IMAGE}" && exit 0
fi

gitlab_login

if [ -n "$MULTIARCH" ] && [ "$ARCH" != "" ]; then
  set +e
  docker run --privileged --rm tonistiigi/binfmt --install "$ARCH"
  set -e
fi

set -x
docker build --no-cache --pull --platform ${PLATFORM} -t "$IMAGE_NAME" -f "$DOCKERFILE" "${BUILD_ARGS[@]}" "$BUILD_DIR"
set +x

mkdir -p results

docker push "$IMAGE_NAME"

if [ -n "$MULTIARCH" ]; then
  FULL_IMAGE_ARCH_SHA=$(docker inspect --format='{{ index .RepoDigests 0 }}' "$IMAGE_NAME")
  mkdir -p "${BUILD_DIR}/results"
  echo "$FULL_IMAGE_ARCH_SHA" > "${BUILD_DIR}/results/${ARCH}"
fi
