#!/bin/bash

set -e

source $(dirname $0)/../share/build-functions.sh

if [ -z "$MULTIARCH" ]; then
  IMAGE_NAME=${FULL_IMAGE}
else
  IMAGE_NAME=${FULL_IMAGE_ARCH}
fi

gitlab_login

if [ -n "$MULTIARCH" ] && [ -n "$ARCH" ]; then
  docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
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
