#!/bin/bash -e

# shellcheck disable=SC1091
source "$(dirname "$0")/../share/build-functions.sh"

gitlab_login

echo "Scanning ${FULL_IMAGE} for vulnerabilities..."

set +e

trivy \
  --cache-dir .trivy \
  image \
  --security-checks "${TRIVY_SECURITY_CHECKS:-vuln,config}" \
  --severity "${TRIVY_SEVERITY:-HIGH,CRITICAL,MEDIUM}" \
  --vuln-type "${TRIVY_VULN_TYPE:-os,library}" \
  --ignore-unfixed \
  --exit-code 2 \
  --no-progress \
  "${FULL_IMAGE}"
EXITCODE=$?

if [ -n "${TRIVY_REPORT_JSON}" ]; then
  echo "Generating Trivy JSON report..."

  trivy \
    --cache-dir .trivy \
    image \
    --severity "${TRIVY_SEVERITY:-HIGH,CRITICAL,MEDIUM}" \
    --vuln-type "${TRIVY_VULN_TYPE:-os,library}" \
    --ignore-unfixed \
    --no-progress \
    --format json \
    "${FULL_IMAGE}" > .trivy-report.json
fi

if [ $EXITCODE -eq 2 ]; then
  echo "Detected vulnerable Docker image ${FULL_IMAGE}..."
  touch .trivy-vulnerable
fi
touch .trivy-run

exit $EXITCODE
