#!/bin/bash

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE" # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"

source /usr/local/share/build-functions.sh

exit_if_image_present

export ARG_BUILDKIT_VERSION="${VERSION}"
# Bake the published tag into the image banner (Dockerfile writes .builder-tag,
# read by build-functions.sh). TAG is pinned to `latest` in .gitlab-ci.yml so all
# jobs agree; mirror it into the banner arg here.
export ARG_BUILDER_TAG="${TAG}"

"${DIR}"/../bin/build-image.sh
