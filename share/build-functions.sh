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

if [ -z "$IMAGE" ]; then
  if [ -n "$CI_REGISTRY_IMAGE" ]; then
    IMAGE=${CI_REGISTRY_IMAGE}
  else
    IMAGE=${CI_PROJECT_PATH/docker/tgbyte}
  fi
fi

if [ -e .version ]; then
  VERSION=$(cat .version)
elif [ -e .gitlab-ci/version.sh ]; then
  VERSION=$(.gitlab-ci/version.sh)
  echo "${VERSION}" > .version
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
  # shellcheck disable=SC2034
  FORCE="1"
fi

if [ -e .trivy-vulnerable ]; then
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
