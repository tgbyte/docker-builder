#!/bin/bash

set -e

source $(dirname $0)/../share/build-functions.sh

if [ -z "$MULTIARCH" ]; then
  echo "Cannot use build-manifest.sh if MULTIARCH is not enabled."
  exit 1
fi

cd results
docker manifest create "$FULL_IMAGE" $(cat *)

for i in *; do
  docker manifest annotate "$FULL_IMAGE" $(cat "$i") --arch "$i"
done

docker manifest push "$FULL_IMAGE"
