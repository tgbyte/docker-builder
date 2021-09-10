#!/bin/bash -e

# shellcheck disable=SC1091
source "$(dirname "$0")/../share/build-functions.sh"

if [ -z "${MULTIARCH}" ]; then
  echo "Cannot use build-manifest.sh if MULTIARCH is not enabled."
  exit 1
fi

gitlab_login
exit_if_image_present

cd "${BUILD_DIR}/results"
echo "Creating Docker manifest ${FULL_IMAGE}..."
# shellcheck disable=SC2046
docker manifest create "${FULL_IMAGE}" $(cat *)

for i in *; do
  # shellcheck disable=SC2046
  docker manifest annotate "${FULL_IMAGE}" $(cat "$i") --arch "$i"
done

echo "Pushing Docker manifest ${FULL_IMAGE}..."
docker manifest push "${FULL_IMAGE}"
