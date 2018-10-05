#!/bin/sh

set -e

source $(dirname $0)/../share/build-functions.sh

cd results
docker manifest create "$FULL_IMAGE" $(cat *)

for i in *
do
  docker manifest annotate "$FULL_IMAGE" $(cat "$i") --arch "$i"
done

docker manifest push "$FULL_IMAGE"
