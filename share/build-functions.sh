#!/bin/bash

[[ "${_BUILD_FUNCTIONS:-""}" == "yes" ]] && return 0
_BUILD_FUNCTIONS=yes

function gitlab_login {
  if [ ! -e .docker-logged-in ]; then
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

      touch .docker-logged-in
    fi
  fi
}

function exit_if_image_present {
  if [ "$FORCE" != "1" ] && [ -z "$VULNERABLE" ]; then
    echo "Checking if ${FULL_IMAGE} already exists..."
    if check-tag.sh "${FULL_IMAGE}"; then
      echo "Docker image ${FULL_IMAGE} already exists - skipping build"
      exit 0
    fi
  fi
}

function build_log {
  if [ "$VERBOSE" == "1" ]; then
    echo "$1"
  fi
}

if [ -z "$IMAGE" ]; then
  if [ -n "$CI_REGISTRY_IMAGE" ]; then
    IMAGE=${CI_REGISTRY_IMAGE}
    build_log "Detected GitLab Container Registry using CI_REGISTRY_IMAGE env variable: ${IMAGE}"
  else
    IMAGE=${CI_PROJECT_PATH/docker/tgbyte}
    build_log "Publishing image on Docker Hub: ${IMAGE}"
  fi
fi

if [ -e .version ]; then
  build_log "Detected existing .version file"
  VERSION=$(cat .version)
elif [ -e .gitlab-ci/version.sh ]; then
  build_log "Determining version using .gitlab-ci/version.sh"
  VERSION=$(.gitlab-ci/version.sh)
  build_log "Detected version: ${VERSION}"
  echo "${VERSION}" > .version
else
  build_log "Cannot determine version"
fi

if [ -z "$TAG" ]; then
  if [ -n "$VERSION" ]; then
    TAG="$VERSION"
  else
    case ${CI_BUILD_REF_NAME} in
    master|main)
      TAG="latest"
      ;;
    *)
      TAG=${CI_BUILD_REF_NAME//[^0-9A-Za-z_.\-]/-}
      ;;
    esac
  fi
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
  build_log "Trivy did not run - forcing build"
  # shellcheck disable=SC2034
  FORCE="1"
fi

if [ -e .trivy-vulnerable ]; then
  build_log "Trivy detected vulnerabilities - forcing build"
  # shellcheck disable=SC2034
  VULNERABLE="1"
fi

if [ -z "${QUIET}" ]; then
  echo "*** IMAGE BUILD SETTINGS ***"
  echo "============================"
  echo "IMAGE: $IMAGE"
  echo "TAG: $TAG"
  echo "ARCH: $ARCH"
  echo BUILD_ARGS: "${BUILD_ARGS[@]}"
  echo "BUILD_DIR: $BUILD_DIR"
  echo "DOCKERFILE: $DOCKERFILE"
  echo "FORCE: $FORCE"
  echo "MULTIARCH: $MULTIARCH"
  echo "VERSION: $VERSION"
  echo "VULNERABLE: $VULNERABLE"
  echo "============================"
fi
