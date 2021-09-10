#!/bin/bash

[[ "${_BUILD_FUNCTIONS:-""}" == "yes" ]] && return 0
_BUILD_FUNCTIONS=yes

function gitlab_login {
  if [ -n "$CI_REGISTRY_IMAGE" ]; then
    if [ -n "$CI_REGISTRY_USER" ]; then
      echo "Detected GitLab Container registry - logging in using CI_REGISTRY_USER..."
      docker login -u "$CI_REGISTRY_USER" -p "$CI_REGISTRY_PASSWORD" "$CI_REGISTRY"
    else
      if [ -n "$CI_DEPLOY_USER" ]; then
        echo "Detected GitLab Container registry - logging in using CI_DEPLOY_USER..."
        docker login -u "$CI_DEPLOY_USER" -p "$CI_DEPLOY_PASSWORD" "$CI_REGISTRY"
      else
        echo "No credentials defined to login to GitLab Container Registry. See https://docs.gitlab.com/ee/ci/docker/using_docker_build.html#authenticating-to-the-container-registry for options."
        exit 1
      fi
    fi
  fi
}

function exit_if_image_present {
  if [ "$FORCE" != "1" ] && [ -z "$VULNERABLE" ]; then
    echo "Checking if ${FULL_IMAGE} already exists..."
    if ! check-tag.sh "${FULL_IMAGE}"; then
      echo "Docker image ${FULL_IMAGE} already exists - skipping build"
      exit 0
    fi
  fi
}

if [ -z "$IMAGE" ]; then
  if [ -n "$CI_REGISTRY_IMAGE" ]; then
    IMAGE=${CI_REGISTRY_IMAGE}
  else
    IMAGE=${CI_PROJECT_PATH/docker/tgbyte}
  fi
fi

if [ -z "$TAG" ]; then
  case ${CI_BUILD_REF_NAME} in
  master|main)
    TAG="latest"
    ;;
  *)
    TAG=${CI_BUILD_REF_NAME//[^0-9A-Za-z_.\-]/-}
    ;;
  esac
fi

if [ -z "$ARCH" ]; then
  ARCH=$(docker version | grep OS/Arch | head -1 | sed s,.\*/,,)
fi

if [ -z "$PLATFORM" ]; then
  PLATFORM=${ARCH}
fi

if [ -z "$BUILD_DIR" ]; then
  BUILD_DIR="."
fi

if [ -z "$BUILD_DIR" ]; then
  DOCKERFILE="${BUILD_DIR}/Dockerfile"
fi

# shellcheck disable=SC2034
FULL_IMAGE_ARCH="$IMAGE":"$TAG"-"$ARCH"
# shellcheck disable=SC2034
FULL_IMAGE="$IMAGE":"$TAG"

declare -a BUILD_ARGS
while IFS='=' read -r -d '' n v; do
    BUILD_ARGS+=("--build-arg")
    BUILD_ARGS+=("$n=$v")
done < <(env -0 | grep -z '^ARG_' | sed -rze 's/^ARG_//')

if [ ! -e .trivy-run ]; then
  # shellcheck disable=SC2034
  FORCE="1"
fi

if [ -e .trivy-vulnerable ]; then
  # shellcheck disable=SC2034
  VULNERABLE="1"
fi

echo "*** IMAGE BUILD SETTINGS ***"
echo "============================"
echo "IMAGE: $IMAGE"
echo "TAG: $TAG"
echo "ARCH: $ARCH"
echo "BUILD_DIR: $BUILD_DIR"
echo "DOCKERFILE: $DOCKERFILE"
echo "MULTIARCH: $MULTIARCH"
echo BUILD_ARGS: "${BUILD_ARGS[@]}"
echo "FORCE: $FORCE"
echo "VULNERABLE: $VULNERABLE"
echo "============================"
