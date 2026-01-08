#!/bin/bash -e

# shellcheck disable=SC1091
source "$(dirname "$0")/../share/build-functions.sh"

if [ -z "${MULTIARCH}" ]; then
  echo "Cannot use build-manifest.sh if MULTIARCH is not enabled."
  exit 1
fi

registry_login
exit_if_image_present

cd "${BUILD_DIR}/results"
echo "Creating manifest list ${FULL_IMAGE}..."
buildah manifest rm "${FULL_IMAGE}" >/dev/null 2>&1 || true
buildah manifest create "${FULL_IMAGE}"

for i in *; do
  digest=$(cat "$i")
  buildah manifest add "${FULL_IMAGE}" "docker://${IMAGE}@${digest}" --arch "$i"
done

echo "Pushing manifest list ${FULL_IMAGE}..."
buildah manifest push --all "${FULL_IMAGE}" "docker://${FULL_IMAGE}"
