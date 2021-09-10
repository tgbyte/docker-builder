#!/bin/bash

set -e

# shellcheck disable=SC1091
source "$(dirname "$0")/../share/build-functions.sh"

gitlab_login

for NEW_TAG in "$@"; do
  NEW_FULL_IMAGE="${IMAGE}:${NEW_TAG}"
  docker tag "${FULL_IMAGE}" "${NEW_FULL_IMAGE}"
  docker push "${NEW_FULL_IMAGE}"
done
