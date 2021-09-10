#!/bin/bash -e

# shellcheck disable=SC1091
source "$(dirname "$0")/../share/build-functions.sh"

if [ -z "$MULTIARCH" ]; then
  echo "Cannot use build-manifest.sh if MULTIARCH is not enabled."
  exit 1
fi

gitlab_login

if [ "$FORCE" != "1" ] && [ -z "$VULNERABLE" ]; then
  echo Exit if "${FULL_IMAGE}" already exists
  check-tag.sh "${FULL_IMAGE}" && exit 0
fi

cd "${BUILD_DIR}/results"
echo "Creating Docker manifest $FULL_IMAGE..."
# shellcheck disable=SC2046
docker manifest create "$FULL_IMAGE" $(cat *)

for i in *; do
  # shellcheck disable=SC2046
  docker manifest annotate "$FULL_IMAGE" $(cat "$i") --arch "$i"
done

echo "Pushing Docker manifest $FULL_IMAGE..."
docker manifest push "$FULL_IMAGE"
