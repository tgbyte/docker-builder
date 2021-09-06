#!/bin/bash -e

# shellcheck disable=SC1091
source "$(dirname "$0")/../share/build-functions.sh"

if [ -z "$MULTIARCH" ]; then
  echo "Cannot use build-manifest.sh if MULTIARCH is not enabled."
  exit 1
fi

if [ ! -e .trivy ]; then
  FORCE="1"
fi

if [ -e .trivy-vulnerable ]; then
  VULNERABLE="1"
fi

if [ "$FORCE" != "1" ] && [ -z "$VULNERABLE" ]; then
  echo Exit if "${FULL_IMAGE}" already exists
  check-tag.sh "${FULL_IMAGE}" && exit 0
fi

gitlab_login

cd "${BUILD_DIR}/results"
# shellcheck disable=SC2046
docker manifest create "$FULL_IMAGE" $(cat *)

for i in *; do
  # shellcheck disable=SC2046
  docker manifest annotate "$FULL_IMAGE" $(cat "$i") --arch "$i"
done

docker manifest push "$FULL_IMAGE"
