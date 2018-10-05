#!/bin/sh

set -xe

source $(dirname $0)/../share/build-functions.sh

docker build --no-cache --pull --platform ${ARCH} -t "$FULL_IMAGE_ARCH" -f "$DOCKERFILE" "$BUILD_DIR"

mkdir -p results
docker push "$FULL_IMAGE_ARCH"
FULL_IMAGE_ARCH_SHA=$(docker inspect --format='{{ index .RepoDigests 0 }}' "$FULL_IMAGE_ARCH")
echo "$FULL_IMAGE_ARCH_SHA" > results/"$ARCH"
