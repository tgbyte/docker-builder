#!/bin/bash

[[ "${_BUILD_FUNCTIONS:-""}" == "yes" ]] && return 0
_BUILD_FUNCTIONS=yes

echo "tgbyte/builder:$(cat /usr/local/etc/.builder-tag 2>/dev/null) - Git commit $(cat /usr/local/etc/.builder-commit) @ $(cat /usr/local/etc/.builder-commit-date)"

function registry_auth {
  if [ -e .docker-logged-in ]; then
    # First call (per job) creates+exports DOCKER_CONFIG/REGISTRY_AUTH_FILE; children inherit them.
    return 0
  fi

  DOCKER_CONFIG="${DOCKER_CONFIG:-$HOME/.docker}"
  REGISTRY_AUTH_FILE="${DOCKER_CONFIG}/config.json"
  export DOCKER_CONFIG REGISTRY_AUTH_FILE
  mkdir -p "${DOCKER_CONFIG}"

  if [ -n "$CI_REGISTRY_IMAGE" ]; then
    registry_auth_gitlab
  else
    registry_auth_docker_hub
  fi
}

# write_auth <registry-host> <username> <password>
function write_auth {
  local reg="$1" user="$2" pass="$3"
  local cfg="${REGISTRY_AUTH_FILE}"
  local token
  token=$(printf '%s:%s' "$user" "$pass" | base64 | tr -d '\n')
  if [ -s "$cfg" ]; then
    jq --arg reg "$reg" --arg auth "$token" \
      '.auths[$reg] = {auth: $auth}' "$cfg" > "${cfg}.tmp"
  else
    jq -n --arg reg "$reg" --arg auth "$token" \
      '{auths: {($reg): {auth: $auth}}}' > "${cfg}.tmp"
  fi
  mv "${cfg}.tmp" "$cfg"
}

function registry_auth_gitlab {
  if [ -n "$CI_REGISTRY_USER" ]; then
    echo "Detected GitLab Container registry - writing auth for CI_REGISTRY_USER..."
    write_auth "$CI_REGISTRY" "$CI_REGISTRY_USER" "$CI_REGISTRY_PASSWORD"
    if [ -n "$BUILD_HELM_CHART" ]; then
      helm registry login "$CI_REGISTRY" \
        --username "$CI_REGISTRY_USER" \
        --password "$CI_REGISTRY_PASSWORD"
    fi
  elif [ -n "$CI_DEPLOY_USER" ]; then
    echo "Detected GitLab Container registry - writing auth for CI_DEPLOY_USER..."
    write_auth "$CI_REGISTRY" "$CI_DEPLOY_USER" "$CI_DEPLOY_PASSWORD"
    helm registry login "$CI_REGISTRY" \
      --username "$CI_DEPLOY_USER" \
      --password "$CI_DEPLOY_PASSWORD"
  else
    echo "No credentials defined to login to GitLab Container Registry. See https://docs.gitlab.com/ee/ci/docker/using_docker_build.html#authenticating-to-the-container-registry for options."
    exit 1
  fi
  touch .docker-logged-in
}

function registry_auth_docker_hub {
  if [ -n "$DOCKER_HUB_USER" ]; then
    echo "Detected Docker Hub - writing auth for DOCKER_HUB_USER..."
    write_auth "https://index.docker.io/v1/" "$DOCKER_HUB_USER" "$DOCKER_HUB_PASSWORD"
    touch .docker-logged-in
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

# Route FROM base images through the Harbor proxy-cache when HARBOR_REGISTRY
# is set: rewrites each FROM in a processed copy of $DOCKERFILE (see
# harbor-rewrite.awk for the registry->project routing) and repoints DOCKERFILE
# at it. No-op when HARBOR_REGISTRY is empty.
function harbor_rewrite_dockerfile {
  [ -n "${HARBOR_REGISTRY:-}" ] || return 0

  if [ ! -f "$DOCKERFILE" ]; then
    build_log "HARBOR_REGISTRY set but Dockerfile '${DOCKERFILE}' not found - skipping Harbor rewrite"
    return 0
  fi

  HARBOR_PROCESSED_DOCKERFILE="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '${HARBOR_PROCESSED_DOCKERFILE}'" EXIT

  awk -v harbor="${HARBOR_REGISTRY%/}" \
    -f "$(dirname "${BASH_SOURCE[0]}")/harbor-rewrite.awk" \
    "$DOCKERFILE" > "${HARBOR_PROCESSED_DOCKERFILE}"

  DOCKERFILE="${HARBOR_PROCESSED_DOCKERFILE}"
  build_log "Routing base images through Harbor proxy-cache at ${HARBOR_REGISTRY}"
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
    case ${CI_COMMIT_REF_NAME} in
    master|main)
      TAG="latest"
      ;;
    *)
      TAG=${CI_COMMIT_REF_NAME//[^0-9A-Za-z_.\-]/-}
      ;;
    esac
  fi
fi

if [ -z "$PLATFORMS" ]; then
  if [ "$MULTIARCH" == "1" ]; then
    PLATFORMS="linux/amd64,linux/arm64"
  else
    PLATFORMS="linux/amd64"
  fi
fi

if [ -z "$BUILD_DIR" ]; then
  BUILD_DIR="."
fi

if [ -z "$DOCKERFILE" ]; then
  DOCKERFILE="${BUILD_DIR}/Dockerfile"
fi

if [ -z "$HELM_CHART_NAME" ]; then
  HELM_CHART_NAME="${CI_PROJECT_NAME}"
fi

if [ -z "$HELM_CHART_DIR" ]; then
  HELM_CHART_DIR="${BUILD_DIR}/charts/${HELM_CHART_NAME}"
fi

if [ -d "$HELM_CHART_DIR" ]; then
  BUILD_HELM_CHART="1"
fi

# shellcheck disable=SC2034
FULL_IMAGE="$IMAGE":"$TAG"
# shellcheck disable=SC2034
HELM_CHART_IMAGE="oci://${IMAGE}/helm"

# Populate the builder-image banner (baked into .builder-commit* via the
# Dockerfile GIT_COMMIT/GIT_COMMIT_DATE args). These MUST be exported: the
# ARG_* -> build-arg harvester below reads `env -0`, which only lists exported
# variables, so a plain assignment here silently yields empty build args.
# Prefer GitLab's predefined vars (always set in CI and immune to the git
# "dubious ownership" issues the rootless build can hit); fall back to git for
# local builds. `|| true` so a missing git repo degrades the banner instead of
# aborting the build.
export ARG_GIT_COMMIT="${CI_COMMIT_SHORT_SHA:-$(git rev-parse --short HEAD 2>/dev/null || true)}"
export ARG_GIT_COMMIT_DATE="${CI_COMMIT_TIMESTAMP:-$(git show -s --format=%cd 2>/dev/null || true)}"

declare -a BUILD_OPTS
while IFS='=' read -r -d '' n v; do
    BUILD_OPTS+=("--opt")
    BUILD_OPTS+=("build-arg:$n=$v")
done < <(env -0 | grep -z '^ARG_' | sed -rze 's/^ARG_//')

if [ ! -e .trivy-run ] && [ "${SKIP_TRIVY}" != "1" ]; then
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
  echo "PLATFORMS: $PLATFORMS"
  echo BUILD_OPTS: "${BUILD_OPTS[@]}"
  echo "BUILD_DIR: $BUILD_DIR"
  echo "DOCKERFILE: $DOCKERFILE"
  echo "FORCE: $FORCE"
  echo "MULTIARCH: $MULTIARCH"
  echo "VERSION: $VERSION"
  echo "VULNERABLE: $VULNERABLE"
  echo "BUILD_HELM_CHART: $BUILD_HELM_CHART"
  echo "============================"
fi
