#!/bin/bash

source "$(dirname "$0")/../share/build-functions.sh"

gitlab_login

trivy \
  --cache-dir .trivy \
  image \
  --ignore-unfixed \
  --exit-code 2 \
  --no-progress \
  "${FULL_IMAGE}"
EXITCODE=$?

if [ $EXITCODE -eq 2 ]; then
  echo "Detected vulnerable Docker image ${FULL_IMAGE} - forcing rebuild"
  touch .trivy-vulnerable
fi
touch .trivy

exit $EXITCODE
