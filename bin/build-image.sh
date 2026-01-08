#!/bin/bash -e

# shellcheck disable=SC1091
source "$(dirname "$0")/../share/build-functions.sh"

if [ -z "${MULTIARCH}" ]; then
  IMAGE_NAME=${FULL_IMAGE}
else
  IMAGE_NAME=${FULL_IMAGE_ARCH}
fi

registry_login
exit_if_image_present

if [ -n "${MULTIARCH}" ] && [ "${ARCH}" != "" ] && [ "${ARCH}" != "amd64" ]; then
  set +e
  binfmt_ctr=$(buildah from --pull docker.io/tonistiigi/binfmt 2>/dev/null)
  if [ -n "${binfmt_ctr}" ]; then
    buildah run "${binfmt_ctr}" --install "${ARCH}"
    buildah rm "${binfmt_ctr}"
  fi
  set -e
fi

if [ -n "${DOCKER_SQUASH}" ]; then
  squash="--squash"
fi

echo "Building image ${IMAGE_NAME}..."
: "${BUILDAH_ISOLATION:=chroot}"
: "${BUILDAH_STORAGE_DRIVER:=vfs}"
export BUILDAH_ISOLATION
export BUILDAH_STORAGE_DRIVER
buildah bud --no-cache --pull --platform "${PLATFORM}" --isolation "${BUILDAH_ISOLATION}" -t "${IMAGE_NAME}" -f "${DOCKERFILE}" ${squash} "${BUILD_ARGS[@]}" "${BUILD_DIR}"

mkdir -p results

if [ -z "${SKIP_DOCKER_PUSH}" ]; then
  echo "Pushing image ${IMAGE_NAME}..."
  buildah push "${IMAGE_NAME}" "docker://${IMAGE_NAME}"

  if [ -n "${MULTIARCH}" ]; then
    FULL_IMAGE_ARCH_SHA=$(skopeo inspect --format '{{.Digest}}' "docker://${IMAGE_NAME}")
    mkdir -p "${BUILD_DIR}/results"
    echo "${FULL_IMAGE_ARCH_SHA}" > "${BUILD_DIR}/results/${ARCH}"
  fi
fi

if [ -n "$BUILD_HELM_CHART" ]; then
  build-helm.sh
fi
