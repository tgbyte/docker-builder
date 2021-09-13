#!/bin/bash -e

# shellcheck disable=SC1091
source "$(dirname "$0")/../share/build-functions.sh"

gitlab_login

echo "Scanning ${FULL_IMAGE} for vulnerabilities..."

set +e

trivy \
  --cache-dir .trivy \
  image \
  --severity "${TRIVY_SEVERITY:-HIGH,CRITICAL,MEDIUM}" \
  --vuln-type "${TRIVY_VULN_TYPE:-os,library}" \
  --ignore-unfixed \
  --exit-code 2 \
  --no-progress \
  "${FULL_IMAGE}"
EXITCODE=$?

if [ $EXITCODE -eq 2 ]; then
  echo "Detected vulnerable Docker image ${FULL_IMAGE}..."
  touch .trivy-vulnerable
fi
touch .trivy-run

exit $EXITCODE
