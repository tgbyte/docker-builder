#!/bin/bash

set -e

# shellcheck disable=SC1091
source "$(dirname "$0")/../share/build-functions.sh"

registry_auth

for NEW_TAG in "$@"; do
  NEW_FULL_IMAGE="${IMAGE}:${NEW_TAG}"
  echo "Copying ${FULL_IMAGE} -> ${NEW_FULL_IMAGE}..."
  skopeo copy --all "docker://${FULL_IMAGE}" "docker://${NEW_FULL_IMAGE}"
done
