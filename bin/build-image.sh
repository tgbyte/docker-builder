#!/bin/bash

set -e

source $(dirname $0)/../share/build-functions.sh

if [ -z "$MULTIARCH" ]; then
  IMAGE_NAME=${FULL_IMAGE}
else
  IMAGE_NAME=${FULL_IMAGE_ARCH}
fi

set -x
docker build --no-cache --pull --platform ${PLATFORM} -t "$IMAGE_NAME" -f "$DOCKERFILE" "${BUILD_ARGS[@]}" "$BUILD_DIR"
set +x

mkdir -p results

if [ -n "$CI_REGISTRY" ]; then
  if [ -n "$CI_REGISTRY_USER" ]; then
    docker login -u $CI_REGISTRY_USER -p $CI_REGISTRY_PASSWORD $CI_REGISTRY
  else
    if [ -n "$CI_DEPLOY_USER" ]; then
      docker login -u $CI_DEPLOY_USER -p $CI_DEPLOY_PASSWORD $CI_REGISTRY
    else
      echo "No credentials defined to login to GitLab Container Registry. See https://docs.gitlab.com/ee/ci/docker/using_docker_build.html#authenticating-to-the-container-registry for options."
      exit 1
    fi
  fi
fi


docker push "$IMAGE_NAME"

if [ -n "$MULTIARCH" ]; then
  FULL_IMAGE_ARCH_SHA=$(docker inspect --format='{{ index .RepoDigests 0 }}' "$IMAGE_NAME")
  echo "$FULL_IMAGE_ARCH_SHA" > results/"$ARCH"
fi
