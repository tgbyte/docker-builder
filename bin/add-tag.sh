#!/bin/bash

set -e

# shellcheck disable=SC1091
source "$(dirname "$0")/../share/build-functions.sh"

registry_login

for NEW_TAG in "$@"; do
  NEW_FULL_IMAGE="${IMAGE}:${NEW_TAG}"
  buildah tag "${FULL_IMAGE}" "${NEW_FULL_IMAGE}"
  buildah push "${NEW_FULL_IMAGE}" "docker://${NEW_FULL_IMAGE}"
done
