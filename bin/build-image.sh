#!/bin/sh

set -e

source $(dirname $0)/../share/build-functions.sh

if [ -z "$MULTIARCH" ]
then
  IMAGE_NAME=${FULL_IMAGE}
else
  IMAGE_NAME=${FULL_IMAGE_ARCH}
fi

docker build --no-cache --pull --platform ${ARCH} -t "$IMAGE_NAME" -f "$DOCKERFILE" "$BUILD_DIR"

mkdir -p results
docker push "$IMAGE_NAME"

if [ -n "$MULTIARCH" ]
then
  FULL_IMAGE_ARCH_SHA=$(docker inspect --format='{{ index .RepoDigests 0 }}' "$IMAGE_NAME")
  echo "$FULL_IMAGE_ARCH_SHA" > results/"$ARCH"
fi
